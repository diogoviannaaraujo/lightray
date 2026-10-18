import CoreGraphics
import Foundation
import LightrayCore

public enum HostInputMode { case inject, log, off }

public struct HostOptions {
    public init() {}
    public var requireCaptureReady = false
    public var port: UInt16 = 7373
    public var frameRate = 60
    public var bitrate = 20_000_000
    public var scale = 1.0
    public var maxDatagramSize = 1200
    public var inputMode = HostInputMode.inject
    public var dropRate = 0.0
    /// A synthetic source of this size instead of the screen, as two displays.
    public var testPattern: (width: Int, height: Int)?
    /// Keep capture ready for the next connection unless an idle timeout is requested.
    public var warmSeconds = Double.infinity
    /// Reed–Solomon parity for clients that offer FEC, as a percentage of each block's data; 0
    /// turns it off. At least `fecMinParity` parity fragments per block.
    public var fecPercent = 10
    public var fecMinParity = 1

    /// The encoder's share of `bitrate`: parity comes out of the same budget, as in Sunshine.
    public var encoderBitrate: Int { bitrate * 100 / (100 + fecPercent) }
}

/// Where the host finds each pairing's key. Called on the host's network queue.
public protocol HostPairings: AnyObject, Sendable {
    /// The key of a pairing the host accepts now, or nil.
    func key(for id: UInt64) -> Bytes?
    /// Rereads the pairings if they changed; true when they did.
    func refresh() -> Bool
    /// A device completed a handshake with this pairing.
    func connected(_ id: UInt64)
}

/// A single pairing that never changes.
public final class FixedPairing: HostPairings {
    public let pairing: Pairing
    public init(_ pairing: Pairing) { self.pairing = pairing }
    public func key(for id: UInt64) -> Bytes? { id == pairing.id ? pairing.psk : nil }
    public func refresh() -> Bool { false }
    public func connected(_ id: UInt64) {}
}

/// Glue between the protocol and the machine. The endpoint, the socket, the timer and the table
/// of pipelines live on `queue`. Each video stream the client binds to a display gets a pipeline,
/// with capture and encoding on a queue of its own; encoded frames come back to `queue`.
public final class HostApp: @unchecked Sendable {
    let options: HostOptions
    let pairings: HostPairings
    let queue = DispatchQueue(label: "lightray.net", qos: .userInteractive)
    let endpoint: HostEndpoint
    private var socket: UDPSocket!
    private var timer: DispatchSourceTimer!
    private var injector: Injector!
    private var stopped = false
    private var displayCallbackRegistered = false

    // On `queue`.
    private var displays: [DisplayInfo] = []
    private var pipelines: [UInt8: Pipeline] = [:]
    /// Counts binding attempts per stream, so that a slow start overtaken by a newer one is dropped.
    private var bindAttempts: [UInt8: Int] = [:]
    private var warmToken = 0
    private var reconfigureToken = 0
    private var displayWatch: DispatchSourceTimer?
    private var prewarming = false
    private var pairingsChecked: UInt64 = 0

    // Statistics, on `queue`.
    private var framesSent: [UInt8: Int] = [:]
    private var lastReport = monotonicMicros()
    private var lastBytes = 0

    public convenience init(options: HostOptions, pairing: Pairing) {
        self.init(options: options, pairings: FixedPairing(pairing))
    }

    public init(options: HostOptions, pairings: HostPairings) {
        self.options = options
        self.pairings = pairings
        var config = HostConfig()
        config.bitrate = options.bitrate
        config.frameRate = options.frameRate
        config.maxDatagramSize = options.maxDatagramSize
        config.fecPercent = options.fecPercent
        config.fecMinParity = options.fecMinParity
        endpoint = HostEndpoint(config: config, hostSecret: randomBytes(32)) { [pairings] id in
            pairings.key(for: id)
        }
    }

    public func run() async throws {
        guard !queue.sync(execute: { stopped }) else { throw CancellationError() }
        let list: [DisplayInfo]
        if let size = options.testPattern {
            list = HostDisplays.testPatterns(width: size.width, height: size.height)
        } else {
            list = try await HostDisplays.current()
        }
        if options.requireCaptureReady && list.isEmpty { throw NSError(domain: "LightrayHost", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display is available to share."]) }
        for display in list {
            log("display \(display.id): \(display.name), \(display.width)×\(display.height)\(display.isPrimary ? ", primary" : "")")
        }
        try queue.sync {
            guard !stopped else { throw CancellationError() }
            injector = Injector(mode: options.inputMode, testPattern: options.testPattern != nil)
            socket = try UDPSocket(family: AF_INET6, port: options.port, queue: queue)
            socket.dropRate = options.dropRate
        }
        // Pay capture/encoder setup once, before accepting the first connection.
        if options.warmSeconds > 0, let primary = list.first(where: \.isPrimary) ?? list.first {
            do {
                let pipeline = try await makePipeline(1, showing: primary)
                let installed = queue.sync {
                    guard !stopped else { return false }
                    pipelines[1] = pipeline
                    watch(pipeline)
                    return true
                }
                guard installed else {
                    pipeline.stop()
                    await pipeline.waitUntilStopped()
                    throw CancellationError()
                }
                log("primary display capture ready at \(pipeline.size.width)×\(pipeline.size.height)")
            } catch {
                if options.requireCaptureReady { throw error }
                log("primary display could not be prepared yet: \(error)")
            }
        }
        try queue.sync {
            guard !stopped else { socket.close(); throw CancellationError() }
            timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            timer.setEventHandler { [weak self] in self?.pump() }
            displays = list
            socket.start { [unowned self] datagram, from in
                endpoint.receive(datagram, from: from, now: monotonicMicros(), unixTime: unixSeconds())
                pump()
            }
            timer.resume()
            if options.testPattern == nil { watchDisplays() }
            keepWarm()
        }
        let fec = options.fecPercent > 0
            ? String(format: ", FEC %d %% (encoder %.1f Mb/s)", options.fecPercent, Double(options.encoderBitrate) / 1_000_000)
            : ", no FEC"
        log("listening on UDP port \(socket.localPort), \(options.bitrate / 1_000_000) Mb/s per display\(fec), datagrams up to \(options.maxDatagramSize) bytes")
        if options.testPattern == nil { await MainActor.run { registerForDisplayChanges() } }
    }

    // MARK: The network queue

    /// Runs the endpoint's timers, sends what it produced, acts on its events, and sleeps until
    /// it next needs waking.
    private func pump() {
        guard !stopped else { return }
        let now = monotonicMicros()
        checkPairings(now: now)
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
            let pairing = endpoint.session.map { String(format: "%016llx", $0.pairingID) } ?? "?"
            log("session \(String(id, radix: 16)) started with \(peer) for device \(pairing), \(endpoint.session?.fec == true ? "FEC on" : "no FEC")")
            if let session = endpoint.session { pairings.connected(session.pairingID) }
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
            prewarmPrimary()
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

    /// Rereads the pairings at most once a second; pump runs at least that often. A session
    /// whose device was revoked ends at once.
    private func checkPairings(now: UInt64) {
        guard now >= pairingsChecked + 1_000_000 else { return }
        pairingsChecked = now
        guard pairings.refresh(), let session = endpoint.session, pairings.key(for: session.pairingID) == nil else { return }
        log("session \(String(session.connection.sessionID, radix: 16)): its device was revoked")
        endpoint.close(now: now, code: .appRequest)
    }

    /// The device of the session that is streaming now, if any.
    public var connectedPairing: UInt64? {
        queue.sync { endpoint.session.flatMap { $0.paused ? nil : $0.pairingID } }
    }

    /// A new session learns the displays, then gets the primary one on its first video stream and
    /// nothing on the rest. Use the watched display list and prepared pipeline immediately;
    /// refresh the list in the background so enumeration cannot delay the first picture.
    private func startSession() {
        guard let session = endpoint.session else { return }
        let started = ObjectIdentifier(session)
        startSession(session)
        let testPattern = options.testPattern != nil
        Task {
            let list = testPattern ? nil : try? await HostDisplays.current()
            queue.async { [self] in
                guard let session = endpoint.session, ObjectIdentifier(session) == started else { return }
                if let list { apply(list) }
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
        guard options.warmSeconds.isFinite else { return }
        queue.asyncAfter(deadline: .now() + options.warmSeconds) { [self] in
            guard token == warmToken, endpoint.session == nil else { return }
            log("warm window over: stopping capture and encoders")
            for stream in Array(pipelines.keys) { unbind(stream) }
        }
    }

    /// Restore the primary standby pipeline after display changes or a capture failure even
    /// without a client. Finite --warm timeouts deliberately opt out of persistent preparation.
    private func prewarmPrimary() {
        guard !stopped, !options.warmSeconds.isFinite, endpoint.session == nil, !prewarming,
              let primary = displays.first(where: \.isPrimary) ?? displays.first else { return }
        if let pipeline = pipelines[1], pipeline.display == primary, pipeline.isCapturing { return }
        prewarming = true
        bindAttempts[1, default: 0] += 1
        start(1, showing: primary, attempt: bindAttempts[1]!, allowIdle: true) { [self] error in
            if let error { log("primary display preparation will retry: \(error)") }
            // Also handle a preparation overtaken by a new display or a short-lived session.
            queue.asyncAfter(deadline: .now() + 2) { [self] in
                prewarming = false
                prewarmPrimary()
            }
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
            // Resuming sends the cached picture immediately, including on a still desktop.
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

    /// Only the currently installed pipeline may send frames. A stopped source or encoder can
    /// complete an old callback after its replacement has started.
    private func makePipeline(_ stream: UInt8, showing info: DisplayInfo) async throws -> Pipeline {
        let id = UUID()
        return try await Pipeline.start(id: id, stream: stream, display: info, options: options) { frame in
            self.queue.async { [self] in
                guard pipelines[stream]?.id == id else { return }
                endpoint.submit(frame, stream: stream, now: monotonicMicros())
                pump()
            }
        }
    }

    /// Starts a binding on the network queue. Superseded client requests must not report a
    /// successful binding; idle preparation still needs its completion to release the retry gate.
    private func start(_ stream: UInt8, showing info: DisplayInfo, attempt: Int, allowIdle: Bool = false,
                       done: @escaping (Error?) -> Void) {
        Task {
            do {
                let pipeline = try await makePipeline(stream, showing: info)
                queue.async { [self] in
                    guard !stopped, attempt == bindAttempts[stream],
                          endpoint.session?.videos[stream] != nil || (allowIdle && endpoint.session == nil) else {
                        pipeline.stop()
                        if allowIdle { done(nil) }
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
                    guard !stopped, attempt == bindAttempts[stream] || allowIdle else { return }
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
        pipeline.onFailure = { [weak self, weak pipeline] reason in
            guard let self else { return }
            self.queue.async {
                guard let pipeline else { return }
                self.captureStopped(pipeline, reason: reason)
            }
        }
    }

    /// On `queue`, once for each pipeline: whichever of the delegate and `watchDisplays` notices first.
    private func captureStopped(_ pipeline: Pipeline, reason: String) {
        let stream = pipeline.stream
        guard pipelines[stream] === pipeline else { return }
        unbind(stream)
        guard endpoint.session?.videos[stream] != nil else {
            log("stream \(stream): \(reason)")
            queue.asyncAfter(deadline: .now() + 0.25) { [self] in prewarmPrimary() }
            return
        }
        log("stream \(stream): \(reason); starting it again")
        bindAttempts[stream, default: 0] += 1
        recover(stream, display: pipeline.display.id, attempt: bindAttempts[stream]!, tries: 0)
    }

    private func recover(_ stream: UInt8, display: UInt32, attempt: Int, tries: Int) {
        let current = { [self] in !stopped && attempt == bindAttempts[stream] && endpoint.session?.videos[stream] != nil }
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
        bindAttempts[stream, default: 0] += 1
        pipelines.removeValue(forKey: stream)?.stop()
        endpoint.resetStream(stream)
    }

    // MARK: Displays changing

    private static let displayCallback: CGDisplayReconfigurationCallBack = { _, flags, context in
        guard !flags.contains(.beginConfigurationFlag), let context else { return }
        Unmanaged<HostApp>.fromOpaque(context).takeUnretainedValue().displaysChanged()
    }

    @MainActor private func registerForDisplayChanges() {
        guard !queue.sync(execute: { stopped }) else { return }
        CGDisplayRegisterReconfigurationCallback(Self.displayCallback, Unmanaged.passUnretained(self).toOpaque())
        displayCallbackRegistered = true
    }

    /// Checks the displays every second as well. The reconfiguration callback did not arrive when a
    /// Screen Sharing session ended and took its virtual display with it, which left the host
    /// offering a display that no longer existed. Capture is checked too, in case a stream stops
    /// without telling its delegate: on a still screen nothing else would show it.
    private func watchDisplays() {
        var seen = HostDisplays.signature()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [unowned self] in
            for pipeline in pipelines.values where !pipeline.isCapturing {
                captureStopped(pipeline, reason: "capture stopped without an error")
            }
            prewarmPrimary()
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
        guard !stopped, list != displays else { return }
        displays = list
        log("displays changed: \(list.map { "\($0.id) \($0.width)×\($0.height)" }.joined(separator: ", "))")
        guard endpoint.session != nil else {
            for (stream, pipeline) in pipelines where !list.contains(where: {
                $0.id == pipeline.display.id && $0.width == pipeline.display.width && $0.height == pipeline.display.height
            }) {
                unbind(stream)
            }
            prewarmPrimary()
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

    /// Stops this runtime without terminating its owner. Safe after failed startup and repeated calls.
    public func stop() async {
        let retiring: [Pipeline] = await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !stopped else { continuation.resume(returning: []); return }
                stopped = true
                log("shutting down")
                warmToken += 1
                reconfigureToken += 1
                bindAttempts.removeAll()
                endpoint.close(now: monotonicMicros())
                for (datagram, to) in endpoint.takeOutbox() { socket?.send(datagram, to: to) }
                injector?.reset()
                timer?.cancel()
                timer = nil
                displayWatch?.cancel()
                displayWatch = nil
                let retiring = Array(pipelines.values)
                for pipeline in retiring { pipeline.stop() }
                pipelines.removeAll()
                socket?.close()
                // The socket's cancel handler closes its descriptor on this queue.
                queue.async { continuation.resume(returning: retiring) }
            }
        }
        await MainActor.run {
            if displayCallbackRegistered {
                CGDisplayRemoveReconfigurationCallback(Self.displayCallback, Unmanaged.passUnretained(self).toOpaque())
                displayCallbackRegistered = false
            }
        }
        for pipeline in retiring { await pipeline.waitUntilStopped() }
    }
}
