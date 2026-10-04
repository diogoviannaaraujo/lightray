import CoreGraphics
import CoreVideo
import Foundation

/// Runs a client: the endpoint, the socket and the timer on one serial queue, and a decoder for
/// each video stream that has shown something, each on a queue of its own. The app hears about
/// the session on the main thread, and gives each stream that delivers a picture a renderer.
///
/// Every handshake starts a new revision. The decoders of the previous one are dropped, and an
/// event it posted that has not reached the app by then is not delivered.
public final class ClientRunner: @unchecked Sendable {
    public struct Settings: Sendable {
        /// The host's name or address.
        public var host: String
        public var port: UInt16
        public var pairing: Pairing
        public var maxDatagramSize = 1200
        /// How many displays can be shown at once: one video stream each.
        public var streams = 4
        /// Offer FEC to the host.
        public var offerFEC = true
        /// For testing repair on a clean network: the fraction of arriving datagrams to drop.
        public var dropRate = 0.0

        public init(host: String, port: UInt16, pairing: Pairing) {
            self.host = host
            self.port = port
            self.pairing = pairing
        }
    }

    public enum Event: Sendable {
        /// A handshake has started; what the streams showed belongs to the previous session.
        case connecting
        /// A session has started, with these video streams.
        case connected(videoStreams: [UInt8])
        /// The session has ended, and a new handshake starts.
        case disconnected
        case displays([DisplayInfo])
        /// What the stream shows now: a display, or 0 for nothing.
        case streamDisplay(stream: UInt8, display: UInt32)
        /// The stream has delivered a frame and has no renderer: give it one with `attach(_:to:)`.
        case needsRenderer(stream: UInt8)
        /// The stream's pictures have a new size, in pixels.
        case pictureSize(stream: UInt8, size: CGSize)
        /// What each stream that decodes reports, once a second.
        case stats([UInt8: StreamReport])
    }

    /// One stream's statistics: a status line, the text of the overlay, and whether its pictures
    /// arrive.
    public struct StreamReport: Sendable {
        public let status: String
        public let overlay: String
        public let state: StreamActivity.State
    }

    public let settings: Settings
    /// Called on the main thread with each event.
    public var onEvent: (@MainActor (Event) -> Void)?
    /// Called on a stream's decode queue with each of its current pictures. Set it before `start`.
    public var onPicture: ((UInt8, CVPixelBuffer) -> Void)?
    private let queue = DispatchQueue(label: "lightray.net", qos: .userInteractive)

    // On `queue`.
    private var endpoint: ClientEndpoint!
    private var socket: UDPSocket!
    private var timer: DispatchSourceTimer!
    private var running = false
    private var revision: UInt64 = 0
    private var decoders: [UInt8: StreamDecoder] = [:]
    private var activities: [UInt8: StreamActivity] = [:]
    private var lastDecoded: [UInt8: Int] = [:]
    private var lastBytes = 0
    private var lastReport = monotonicMicros()
    private var lastLogged = monotonicMicros()
    private var connectedAt: UInt64 = 0
    private var firstDecodeLogged = Set<UInt8>()

    // On the main thread.
    private var deliveredRevision: UInt64 = 0
    private var stopped = false

    public init(settings: Settings) {
        self.settings = settings
    }

    /// Resolves the host and starts the handshake. Throws if the name does not resolve or the
    /// socket cannot open.
    public func start() throws {
        let (address, family) = try UDPSocket.resolve(settings.host, port: settings.port)
        var config = ClientConfig(pairingID: settings.pairing.id, psk: settings.pairing.psk, host: address)
        config.maxDatagramSize = settings.maxDatagramSize
        config.videoStreamCount = settings.streams
        config.offerFEC = settings.offerFEC
        endpoint = ClientEndpoint(config: config, unixTime: unixSeconds)
        socket = try UDPSocket(family: family, queue: queue)
        socket.dropRate = settings.dropRate
        for warning in socket.optionWarnings { log("socket: \(warning)") }
        log("socket buffers: receive \(socket.receiveBufferBytes), send \(socket.sendBufferBytes) bytes")
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.setEventHandler { [weak self] in self?.pump() }
        log("connecting to \(address) from port \(socket.localPort), with \(settings.streams) video streams")
        queue.async { [self] in
            running = true
            socket.start { [weak self] datagram, from in
                guard let self, running else { return }
                endpoint.receive(datagram, from: from, now: monotonicMicros())
                pump()
            }
            timer.resume()
            endpoint.start(now: monotonicMicros())
            pump()
        }
    }

    /// Ends the session, telling the host, and stops the socket, the timer and the decoders. No
    /// event is delivered after it. On the main thread.
    public func stop() {
        stopped = true
        queue.sync {
            running = false
            timer?.cancel()
            endpoint?.close(now: monotonicMicros())
            for datagram in endpoint?.takeOutboundDatagrams() ?? [] { socket?.send(datagram.bytes, to: datagram.destination) }
            for decoder in decoders.values { decoder.invalidate() }
            decoders.removeAll()
            socket?.close()
        }
    }

    public func send(_ message: InputMessage) {
        queue.async { [self] in
            guard running else { return }
            endpoint.send(message, now: monotonicMicros())
            pump()
        }
    }

    /// Asks the host to show `display` on `stream`. Asking for 0, nothing, also stops decoding the
    /// stream.
    public func selectDisplay(_ display: UInt32, on stream: UInt8) {
        queue.async { [self] in
            guard running else { return }
            endpoint.selectDisplay(display, on: stream)
            if display == 0 { decoders.removeValue(forKey: stream)?.invalidate() }
            pump()
        }
    }

    /// Shows the stream's pictures with `renderer`, starting with the newest already decoded.
    public func attach(_ renderer: VideoRenderer, to stream: UInt8) {
        queue.async { [self] in decoders[stream]?.attach(renderer) }
    }

    /// Stops decoding the stream until it delivers a frame again.
    public func stopDecoding(_ stream: UInt8) {
        queue.async { [self] in decoders.removeValue(forKey: stream)?.invalidate() }
    }

    // MARK: On `queue`

    /// Runs the endpoint's timers, sends what it produced, acts on its events, and sleeps until
    /// it next needs waking.
    private func pump() {
        guard running else { return }
        let now = monotonicMicros()
        endpoint.tick(now: now)
        for datagram in endpoint.takeOutboundDatagrams() { socket.send(datagram.bytes, to: datagram.destination) }
        for event in endpoint.takeEvents() { handle(event) }
        let wake = endpoint.nextWakeup(now: now) ?? now + 1_000_000
        timer.schedule(deadline: .now() + .microseconds(Int(min(wake > now ? wake - now : 0, 1_000_000))), leeway: .microseconds(100))
        report(now: now)
    }

    private func handle(_ event: ClientEvent) {
        switch event {
        case .connecting:
            reset()
            post(.connecting, revision: revision)
        case .connected(let id, let size, let streams):
            connectedAt = monotonicMicros()
            let fec = endpoint.session?.fec == true ? "FEC on" : "no FEC"
            log("session \(String(id, radix: 16)) established, datagrams up to \(size) bytes, \(fec), video streams \(streams)")
            post(.connected(videoStreams: streams), revision: revision)
        case .disconnected(let reason):
            log("disconnected: \(reason)")
            reset()
            post(.disconnected, revision: revision)
        case .displays(let list):
            post(.displays(list), revision: revision)
        case .streamDisplay(let stream, let display):
            post(.streamDisplay(stream: stream, display: display), revision: revision)
        case .frame(let stream, let frame):
            // A frame the decode queue gives up on is lost, and the endpoint asks for a keyframe.
            if let lost = decoder(for: stream).submit(frame) { endpoint.decoderFailed(stream: stream, frameID: lost) }
        }
    }

    /// A new handshake: the previous session's decoders and statistics go.
    private func reset() {
        revision &+= 1
        for decoder in decoders.values { decoder.invalidate() }
        decoders.removeAll()
        activities.removeAll()
        lastDecoded.removeAll()
        firstDecodeLogged.removeAll()
        connectedAt = 0
        lastBytes = 0
        lastReport = monotonicMicros()
    }

    /// Hands an event to the app on the main thread, unless the runner has stopped by then, the
    /// event's revision has passed, or `isCurrent` says it is stale. `.connecting` and
    /// `.disconnected` start the revision they carry. From any queue.
    private func post(_ event: Event, revision: UInt64, isCurrent: (@Sendable () -> Bool)? = nil) {
        DispatchQueue.main.async { [self] in
            guard !stopped else { return }
            switch event {
            case .connecting, .disconnected:
                deliveredRevision = revision
            default:
                guard revision == deliveredRevision, isCurrent?() ?? true else { return }
            }
            onEvent?(event)
        }
    }

    /// Whether a result from `decoder` still counts: its stream and revision are current, and so is
    /// the decoder's epoch.
    private func isCurrent(_ decoder: StreamDecoder, stream: UInt8, revision: UInt64, epoch: UInt64) -> Bool {
        self.revision == revision && decoders[stream] === decoder && decoder.isCurrent(epoch)
    }

    /// The stream's decoder, created at its first frame together with a request for a renderer.
    private func decoder(for stream: UInt8) -> StreamDecoder {
        if let decoder = decoders[stream] { return decoder }
        let decoder = StreamDecoder(stream: stream)
        let revision = revision
        decoders[stream] = decoder
        lastDecoded[stream] = 0
        // Results come back on the decoder's queue; only what the endpoint needs crosses over.
        decoder.onResult = { [weak self, weak decoder] result, epoch in
            guard let self, let decoder else { return }
            switch result {
            case .picture(_, let id, let isKeyframe):
                queue.async { [self] in
                    guard isCurrent(decoder, stream: stream, revision: revision, epoch: epoch) else { return }
                    if firstDecodeLogged.insert(stream).inserted, connectedAt != 0 {
                        log("stream \(stream): first_decoded_frame_us=\(monotonicMicros() - connectedAt) after_authenticated_connection")
                    }
                    endpoint.decoded(stream: stream, frameID: id, isKeyframe: isKeyframe)
                }
            case .failed(let id, let status):
                queue.async { [self] in
                    guard isCurrent(decoder, stream: stream, revision: revision, epoch: epoch) else { return }
                    log("stream \(stream): frame \(id) failed to decode (\(status)); asking for a keyframe")
                    endpoint.decoderFailed(stream: stream, frameID: id)
                    pump()
                }
            }
        }
        decoder.onSize = { [weak self, weak decoder] size, epoch in
            self?.post(.pictureSize(stream: stream, size: size), revision: revision) { [weak decoder] in
                decoder?.isCurrent(epoch) == true
            }
        }
        if let onPicture {
            decoder.onPicture = { [weak decoder] pixels, epoch in
                guard decoder?.isCurrent(epoch) == true else { return }
                onPicture(stream, pixels)
            }
        }
        post(.needsRenderer(stream: stream), revision: revision) { [weak decoder] in decoder?.isActive == true }
        return decoder
    }

    private func report(now: UInt64) {
        guard now >= lastReport + 1_000_000, let session = endpoint.session else { return }
        let seconds = Double(now - lastReport) / 1_000_000
        lastReport = now
        let c = session.connection
        let mbps = Double(c.stats.bytesReceived - lastBytes) * 8 / seconds / 1_000_000
        lastBytes = c.stats.bytesReceived
        var reports: [UInt8: StreamReport] = [:]
        for (stream, decoder) in decoders {
            let decoded = decoder.decoded
            let state = activities[stream, default: StreamActivity()].observe(decodedCount: decoded, now: now)
            let fps = Double(decoded - lastDecoded[stream, default: 0]) / seconds
            lastDecoded[stream] = decoded
            let v = session.videos[stream]?.stats ?? VideoReceiverStats()
            let timings = decoder.takeTimings()
            func ms(_ value: Double?) -> String { value.map { String(format: "%.2f ms", $0) } ?? "—" }
            let rtt = ms(c.rtt.hasSample ? Double(c.rtt.smoothed) / 1000 : nil)
            let decode = ms(timings.meanDecodeMillis), wait = ms(timings.meanQueueMillis)
            let capture = ms(timings.meanCaptureMillis), encode = ms(timings.meanEncodeMillis)
            let overlay = "Capture/convert \(capture) · Encode \(encode)\nNetwork RTT \(rtt)\nDecode \(decode) · Queue \(wait)\n"
                + String(format: "%.0f decoded FPS · %.1f Mb/s (connection)\nLost %d · Decode drops %d", fps, mbps,
                         v.framesLost + v.framesUndecodable, decoder.dropped)
            var status = String(
                format: "%.0f decoded fps · %.1f connection Mb/s · RTT %.1f ms · lost %d · keyframes %d · FEC-repaired %d · NACKed %d", fps,
                mbps, Double(c.rtt.smoothed) / 1000, v.framesLost + v.framesUndecodable, v.keyframesDelivered, v.fecRepaired,
                v.nackedFragments)
            status += " · capture/convert \(capture) · encode \(encode) · decode \(decode) · decode wait \(wait)"
            if let sample = timings.lastHostSample {
                status += " · host sample \(sample.sampleID) capture_us \(sample.captureMicros) encode_us \(sample.encodeMicros)"
            }
            reports[stream] = StreamReport(status: status, overlay: overlay, state: state)
        }
        post(.stats(reports), revision: revision)
        if now >= lastLogged + 5_000_000 {
            lastLogged = now
            for stream in reports.keys.sorted() {
                log("stream \(stream): \(reports[stream]!.status) · decode queue drops \(decoders[stream]?.dropped ?? 0) · send errors \(socket.sendFailures) · receive errors \(socket.receiveFailures) · \(socket.dropped) datagrams dropped on purpose")
            }
        }
    }
}
