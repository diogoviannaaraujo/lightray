import CoreGraphics
import Foundation
import LightrayCore
import LightrayMac

struct HostOptions {
    var port: UInt16 = 7373
    var frameRate = 60
    var bitrate = 20_000_000
    var scale = 1.0
    var maxDatagramSize = 1200
    var inputMode = Injector.Mode.inject
    var dropRate = 0.0
    /// A synthetic source of this size instead of the screen, as two displays.
    var testPattern: (width: Int, height: Int)?
    /// How long capture and encoders stay warm after a session ends.
    var warmSeconds = 300.0
    /// Reed–Solomon parity for clients that offer FEC, as a percentage of each block's data; 0
    /// turns it off. At least `fecMinParity` parity fragments per block.
    var fecPercent = 10
    var fecMinParity = 1

    /// The encoder's share of `bitrate`: parity comes out of the same budget, as in Sunshine.
    var encoderBitrate: Int { bitrate * 100 / (100 + fecPercent) }
}

/// Glue between the protocol and the machine. The endpoint, the socket, the timer and the table
/// of pipelines live on `queue`. Each video stream the client binds to a display gets a pipeline,
/// with capture and encoding on a queue of its own; encoded frames come back to `queue`.
final class HostApp: @unchecked Sendable {
    let options: HostOptions
    let pairing: Pairing
    let queue = DispatchQueue(label: "lightray.net", qos: .userInteractive)
    let endpoint: HostEndpoint
    private var socket: UDPSocket!
    private var timer: DispatchSourceTimer!
    private var injector: Injector!
    private var signals: [DispatchSourceSignal] = []

    // On `queue`.
    private var displays: [DisplayInfo] = []
    private var pipelines: [UInt8: Pipeline] = [:]
    /// Counts binding attempts per stream, so that a slow start overtaken by a newer one is dropped.
    private var bindAttempts: [UInt8: Int] = [:]
    private var warmToken = 0
    private var reconfigureToken = 0
    private var displayWatch: DispatchSourceTimer?

    // Statistics, on `queue`.
    private var framesSent: [UInt8: Int] = [:]
    private var lastReport = monotonicMicros()
    private var lastBytes = 0

    init(options: HostOptions, pairing: Pairing) {
        self.options = options
        self.pairing = pairing
        var config = HostConfig()
        config.bitrate = options.bitrate
        config.frameRate = options.frameRate
        config.maxDatagramSize = options.maxDatagramSize
        config.fecPercent = options.fecPercent
        config.fecMinParity = options.fecMinParity
        endpoint = HostEndpoint(config: config, hostSecret: randomBytes(32)) { [pairing] id in
            id == pairing.id ? pairing.psk : nil
        }
    }

    func run() async throws {
        let list: [DisplayInfo]
        if let size = options.testPattern {
            list = HostDisplays.testPatterns(width: size.width, height: size.height)
        } else {
            list = try await HostDisplays.current()
            await MainActor.run { registerForDisplayChanges() }
            watchDisplays()
        }
        for display in list {
            log("display \(display.id): \(display.name), \(display.width)×\(display.height)\(display.isPrimary ? ", primary" : "")")
        }
        injector = Injector(mode: options.inputMode, testPattern: options.testPattern != nil)

        socket = try UDPSocket(family: AF_INET6, port: options.port, queue: queue)
        socket.dropRate = options.dropRate
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.setEventHandler { [unowned self] in pump() }
        queue.sync {
            displays = list
            socket.start { [unowned self] datagram, from in
                endpoint.receive(datagram, from: from, now: monotonicMicros(), unixTime: unixSeconds())
                pump()
            }
            timer.resume()
        }
        let fec = options.fecPercent > 0
            ? String(format: ", FEC %d %% (encoder %.1f Mb/s)", options.fecPercent, Double(options.encoderBitrate) / 1_000_000)
            : ", no FEC"
        log("listening on UDP port \(socket.localPort), \(options.bitrate / 1_000_000) Mb/s per display\(fec), datagrams up to \(options.maxDatagramSize) bytes")

        for signal in [SIGINT, SIGTERM] {
            Darwin.signal(signal, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signal, queue: queue)
            source.setEventHandler { [unowned self] in shutdown() }
            source.resume()
            signals.append(source)
        }
    }

    // MARK: The network queue

    /// Runs the endpoint's timers, sends what it produced, acts on its events, and sleeps until
    /// it next needs waking.
    private func pump() {
        let now = monotonicMicros()
        endpoint.tick(now: now)
        for (datagram, to) in endpoint.takeOutbox() { socket.send(datagram, to: to) }
        for event in endpoint.takeEvents() { handle(event) }
        // Events can queue control messages; send them now rather than at the next wake.
        endpoint.tick(now: now)
        for (datagram, to) in endpoint.takeOutbox() { socket.send(datagram, to: to) }
        let wake = endpoint.nextWakeup(now: now) ?? now + 1_000_000
        timer.schedule(deadline: .now() + .microseconds(Int(min(wake > now ? wake - now : 0, 1_000_000))), leeway: .microseconds(100))
        report(now: now)
    }

    private func handle(_ event: HostEvent) {
        switch event {
        case .sessionStarted(let id, let peer):
            log("session \(String(id, radix: 16)) started with \(peer), \(endpoint.session?.fec == true ? "FEC on" : "no FEC")")
            // The new session's counters start from zero.
            lastBytes = 0
            framesSent.removeAll()
            warmToken += 1
            startSession()
        case .sessionEnded(let id, let reason):
            log("session \(String(id, radix: 16)) ended: \(reason)")
            injector.reset()
            for pipeline in pipelines.values { pipeline.setStreaming(false) }
            keepWarm()
        case .paused:
            log("client silent: media paused, capture and encoders kept warm")
            injector.reset()
            for pipeline in pipelines.values { pipeline.setStreaming(false) }
        case .resumed:
            log("client back: resuming")
            for pipeline in pipelines.values { pipeline.setStreaming(true) }
        case .keyframeNeeded(let stream):
            pipelines[stream]?.requestKeyframe()
        case .displayRequested(let stream, let display, let reqID):
            bind(stream, to: display, reqID: reqID)
        case .input(let message):
            injector.handle(message, displays: displays)
        }
    }

    /// A new session learns the displays, then gets the primary one on its first video stream and
    /// nothing on the rest. A pipeline still warm from an earlier session is reused. The list is
    /// read again first: macOS does not always announce a change (see `watchDisplays`).
    private func startSession() {
        guard let started = endpoint.session.map(ObjectIdentifier.init) else { return }
        let testPattern = options.testPattern != nil
        Task {
            let list = testPattern ? nil : try? await HostDisplays.current()
            queue.async { [self] in
                guard let session = endpoint.session, ObjectIdentifier(session) == started else { return }
                if let list { apply(list) }
                startSession(session)
                pump()
            }
        }
    }

    private func startSession(_ session: HostSession) {
        endpoint.send(.displays(displays))
        let streams = session.videoStreams
        for (stream, pipeline) in pipelines where stream != streams.first {
            pipeline.stop()
            pipelines[stream] = nil
        }
        for stream in streams.dropFirst() { endpoint.send(.streamDisplay(stream: stream, display: 0)) }
        guard let first = streams.first else { return }
        if let primary = displays.first(where: \.isPrimary) ?? displays.first {
            bind(first, to: primary.id, reqID: nil)
        } else {
            endpoint.send(.streamDisplay(stream: first, display: 0))
        }
    }

    /// Stops every pipeline once the warm window passes without a new session.
    private func keepWarm() {
        warmToken += 1
        let token = warmToken
        queue.asyncAfter(deadline: .now() + options.warmSeconds) { [self] in
            guard token == warmToken, endpoint.session == nil else { return }
            log("warm window over: stopping capture and encoders")
            for pipeline in pipelines.values { pipeline.stop() }
            pipelines.removeAll()
        }
    }

    // MARK: Binding streams to displays

    private func reply(_ reqID: UInt32?, stream: UInt8, display: UInt32) {
        if let reqID {
            endpoint.send(.displaySelected(reqID: reqID, stream: stream, display: display))
        } else {
            endpoint.send(.streamDisplay(stream: stream, display: display))
        }
    }

    /// Shows `display` on `stream`, or nothing for 0, and tells the client what the stream shows
    /// afterwards: the new display, or the old one if the new one could not be started.
    private func bind(_ stream: UInt8, to display: UInt32, reqID: UInt32?) {
        bindAttempts[stream, default: 0] += 1
        let attempt = bindAttempts[stream]!
        if display == 0 {
            unbind(stream)
            reply(reqID, stream: stream, display: 0)
            return
        }
        guard let info = displays.first(where: { $0.id == display }) else {
            reply(reqID, stream: stream, display: pipelines[stream]?.display.id ?? 0)
            return
        }
        if let current = pipelines[stream], current.display.id == info.id, current.display.width == info.width,
            current.display.height == info.height
        {
            // Already showing it: the stream carries on. A new session has its keyframe from
            // `keyframeNeeded`, and resuming streaming starts with one.
            current.setStreaming(endpoint.isStreaming)
            reply(reqID, stream: stream, display: display)
            return
        }
        start(stream, showing: info, attempt: attempt) { [self] error in
            if let error {
                log("stream \(stream) cannot show \(info.name): \(error)")
                reply(reqID, stream: stream, display: pipelines[stream]?.display.id ?? 0)
            } else {
                reply(reqID, stream: stream, display: display)
            }
        }
    }

    /// Starts capturing and encoding `info` for `stream`, then, on `queue`, puts the pipeline in
    /// place and calls `done(nil)`, or calls `done` with the error. A start overtaken by a newer
    /// attempt is stopped and not reported.
    private func start(_ stream: UInt8, showing info: DisplayInfo, attempt: Int, done: @escaping (Error?) -> Void) {
        Task {
            do {
                let pipeline = try await Pipeline.start(stream: stream, display: info, options: options) { frame in
                    self.queue.async { [self] in
                        endpoint.submit(frame, stream: stream, now: monotonicMicros())
                        pump()
                    }
                }
                queue.async { [self] in
                    guard attempt == bindAttempts[stream], endpoint.session?.videos[stream] != nil else {
                        pipeline.stop()
                        return
                    }
                    pipelines[stream]?.stop()
                    endpoint.resetStream(stream)
                    pipelines[stream] = pipeline
                    watch(pipeline)
                    pipeline.setStreaming(endpoint.isStreaming)
                    log("stream \(stream) shows \(info.name) at \(pipeline.size.width)×\(pipeline.size.height)")
                    done(nil)
                    pump()
                }
            } catch {
                queue.async { [self] in
                    done(error)
                    pump()
                }
            }
        }
    }

    /// Capture stops on its own when macOS reconfigures the display: its mode changes, a Screen
    /// Sharing session that added a virtual display ends, the screen locks. The stream keeps its
    /// display and capture starts again, backing off to every 2 s while it fails, until it works,
    /// the display goes away, the client asks for something else, or the session ends. The client
    /// keeps its window and gets a keyframe, of the new size if the mode changed.
    private func watch(_ pipeline: Pipeline) {
        let stream = pipeline.stream
        pipeline.onFailure = { [weak self, weak pipeline] reason in
            guard let self else { return }
            self.queue.async {
                guard let pipeline, self.pipelines[stream] === pipeline else { return }
                self.unbind(stream)
                guard self.endpoint.session?.videos[stream] != nil else {
                    log("stream \(stream): \(reason)")
                    return
                }
                log("stream \(stream): \(reason); starting it again")
                self.bindAttempts[stream, default: 0] += 1
                self.recover(stream, display: pipeline.display.id, attempt: self.bindAttempts[stream]!, tries: 0)
            }
        }
    }

    private func recover(_ stream: UInt8, display: UInt32, attempt: Int, tries: Int) {
        let current = { [self] in attempt == bindAttempts[stream] && endpoint.session?.videos[stream] != nil }
        queue.asyncAfter(deadline: .now() + min(0.25 * Double(1 << min(tries, 3)), 2)) { [self] in
            guard current() else { return }
            Task {
                // The list first: the display may be gone, or back in another mode.
                let list = try? await HostDisplays.current()
                queue.async { [self] in
                    guard current() else { return }
                    if let list { apply(list) }
                    guard let info = displays.first(where: { $0.id == display }) else {
                        log("stream \(stream): display \(display) is gone")
                        endpoint.send(.streamDisplay(stream: stream, display: 0))
                        pump()
                        return
                    }
                    start(stream, showing: info, attempt: attempt) { [self] error in
                        guard let error, current() else { return }
                        if tries == 0 { log("stream \(stream) cannot show \(info.name) yet (\(error)); still trying") }
                        recover(stream, display: display, attempt: attempt, tries: tries + 1)
                    }
                }
            }
        }
    }

    private func unbind(_ stream: UInt8) {
        pipelines.removeValue(forKey: stream)?.stop()
        endpoint.resetStream(stream)
    }

    // MARK: Displays changing

    private func registerForDisplayChanges() {
        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            guard !flags.contains(.beginConfigurationFlag), let context else { return }
            Unmanaged<HostApp>.fromOpaque(context).takeUnretainedValue().displaysChanged()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Checks the displays every second as well. The reconfiguration callback did not arrive when a
    /// Screen Sharing session ended and took its virtual display with it, which left the host
    /// offering a display that no longer existed.
    private func watchDisplays() {
        var seen = HostDisplays.signature()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [unowned self] in
            let now = HostDisplays.signature()
            guard now != seen else { return }
            seen = now
            displaysChanged()
        }
        timer.resume()
        displayWatch = timer
    }

    /// Several callbacks arrive for one change; act half a second after the last.
    private func displaysChanged() {
        queue.async { [self] in
            reconfigureToken += 1
            let token = reconfigureToken
            queue.asyncAfter(deadline: .now() + 0.5) { [self] in
                guard token == reconfigureToken else { return }
                Task {
                    guard let list = try? await HostDisplays.current() else { return }
                    queue.async { [self] in apply(list) }
                }
            }
        }
    }

    /// A display that went away unbinds its streams; one whose mode changed restarts them, which
    /// produces a keyframe of the new size. Every change sends the new list.
    private func apply(_ list: [DisplayInfo]) {
        guard list != displays else { return }
        displays = list
        log("displays changed: \(list.map { "\($0.id) \($0.width)×\($0.height)" }.joined(separator: ", "))")
        guard endpoint.session != nil else {
            for (stream, pipeline) in pipelines where !list.contains(where: { $0.id == pipeline.display.id }) {
                unbind(stream)
            }
            return
        }
        endpoint.send(.displays(list))
        for (stream, pipeline) in pipelines {
            guard let info = list.first(where: { $0.id == pipeline.display.id }) else {
                unbind(stream)
                endpoint.send(.streamDisplay(stream: stream, display: 0))
                continue
            }
            if info.width != pipeline.display.width || info.height != pipeline.display.height {
                pipelines[stream] = nil
                pipeline.stop()
                bind(stream, to: info.id, reqID: nil)
            }
        }
        pump()
    }

    // MARK: Reporting and shutdown

    private func report(now: UInt64) {
        guard now >= lastReport + 5_000_000 else { return }
        defer { lastReport = now }
        guard let session = endpoint.session else { return }
        let c = session.connection
        let seconds = Double(now - lastReport) / 1_000_000
        let mbps = Double(c.stats.bytesSent - lastBytes) * 8 / seconds / 1_000_000
        lastBytes = c.stats.bytesSent
        var perStream: [String] = []
        for stream in session.videoStreams {
            let v = session.videos[stream]!.stats
            let fps = Double(v.frames - framesSent[stream, default: 0]) / seconds
            framesSent[stream] = v.frames
            guard let pipeline = pipelines[stream] else { continue }
            perStream.append(String(
                format: "stream %d (%@) %.0f fps, keyframes %d, parity %d, retransmitted %d, expired %d", stream,
                pipeline.display.name, fps, v.keyframes, v.parityFragments, v.retransmissions, v.expired))
        }
        log(String(format: "%@ %.1f Mb/s rtt %.1f ms, peer lost %d/%d | %@", session.paused ? "paused" : "streaming",
                   mbps, Double(c.rtt.smoothed) / 1000, c.stats.reportedLost, c.stats.reportedLost + c.stats.reportedReceived,
                   perStream.isEmpty ? "no display shown" : perStream.joined(separator: " | ")))
    }

    private func shutdown() {
        log("shutting down")
        endpoint.close(now: monotonicMicros())
        for (datagram, to) in endpoint.takeOutbox() { socket.send(datagram, to: to) }
        injector?.reset()
        exit(0)
    }
}
