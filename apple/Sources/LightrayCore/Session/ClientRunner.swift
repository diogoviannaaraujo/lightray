import CoreGraphics
import CoreVideo
import Foundation

/// Runs a client: the endpoint, the socket and the timer on one serial queue, and a decoder for
/// each video stream that has shown something, each on a queue of its own. The app hears about
/// the session on the main thread, and gives each stream that delivers a picture a renderer.
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
        /// A line of statistics for each stream that decodes, once a second.
        case stats([UInt8: String])
    }

    public let settings: Settings
    /// Called on the main thread with each event.
    public var onEvent: (@MainActor (Event) -> Void)?
    /// Called on a stream's decode queue with each of its pictures. Set it before `start`.
    public var onPicture: ((UInt8, CVPixelBuffer) -> Void)?
    private let queue = DispatchQueue(label: "lightray.net", qos: .userInteractive)

    // On `queue`.
    private var endpoint: ClientEndpoint!
    private var socket: UDPSocket!
    private var timer: DispatchSourceTimer!
    private var decoders: [UInt8: StreamDecoder] = [:]
    private var lastDecoded: [UInt8: Int] = [:]
    private var lastBytes = 0
    private var lastReport = monotonicMicros()
    private var lastLogged = monotonicMicros()

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
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.setEventHandler { [unowned self] in pump() }
        log("connecting to \(address) from port \(socket.localPort), with \(settings.streams) video streams")
        queue.async { [self] in
            socket.start { [unowned self] datagram, from in
                endpoint.receive(datagram, from: from, now: monotonicMicros())
                pump()
            }
            timer.resume()
            endpoint.start(now: monotonicMicros())
            pump()
        }
    }

    /// Ends the session, telling the host, before the app quits.
    public func close() {
        queue.sync {
            endpoint?.close(now: monotonicMicros())
            for datagram in endpoint?.takeOutbox() ?? [] { socket.send(datagram, to: endpoint.config.host) }
        }
    }

    public func send(_ message: InputMessage) {
        queue.async { [self] in
            endpoint.send(message, now: monotonicMicros())
            pump()
        }
    }

    /// Asks the host to show `display` on `stream`. Asking for 0, nothing, also stops decoding the
    /// stream.
    public func selectDisplay(_ display: UInt32, on stream: UInt8) {
        queue.async { [self] in
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
        let now = monotonicMicros()
        endpoint.tick(now: now)
        for datagram in endpoint.takeOutbox() { socket.send(datagram, to: endpoint.config.host) }
        for event in endpoint.takeEvents() { handle(event) }
        let wake = endpoint.nextWakeup(now: now) ?? now + 1_000_000
        timer.schedule(deadline: .now() + .microseconds(Int(min(wake > now ? wake - now : 0, 1_000_000))), leeway: .microseconds(100))
        report(now: now)
    }

    private func handle(_ event: ClientEvent) {
        switch event {
        case .connecting:
            post(.connecting)
        case .connected(let id, let size, let streams):
            let fec = endpoint.session?.fec == true ? "FEC on" : "no FEC"
            log("session \(String(id, radix: 16)) established, datagrams up to \(size) bytes, \(fec), video streams \(streams)")
            post(.connected(videoStreams: streams))
        case .disconnected(let reason):
            log("disconnected: \(reason)")
            for decoder in decoders.values { decoder.invalidate() }
            decoders.removeAll()
            post(.disconnected)
        case .displays(let list):
            post(.displays(list))
        case .streamDisplay(let stream, let display):
            post(.streamDisplay(stream: stream, display: display))
        case .frame(let stream, let frame):
            decoder(for: stream).submit(frame)
        }
    }

    /// Hands an event to the app on the main thread. From any queue.
    private func post(_ event: Event) {
        DispatchQueue.main.async { [self] in onEvent?(event) }
    }

    /// The stream's decoder, created at its first frame together with a request for a renderer.
    private func decoder(for stream: UInt8) -> StreamDecoder {
        if let decoder = decoders[stream] { return decoder }
        let decoder = StreamDecoder(stream: stream)
        decoders[stream] = decoder
        // Results come back on the decoder's queue; only what the endpoint needs crosses over.
        decoder.onResult = { [unowned self] result in
            switch result {
            case .picture(_, let id, let isKeyframe):
                queue.async { [self] in endpoint.decoded(stream: stream, frameID: id, isKeyframe: isKeyframe) }
            case .failed(let id, let status):
                queue.async { [self] in
                    log("stream \(stream): frame \(id) failed to decode (\(status)); asking for a keyframe")
                    endpoint.decoderFailed(stream: stream, frameID: id)
                    pump()
                }
            }
        }
        decoder.onSize = { [unowned self] size in post(.pictureSize(stream: stream, size: size)) }
        if let onPicture {
            decoder.onPicture = { pixels in onPicture(stream, pixels) }
        }
        post(.needsRenderer(stream: stream))
        return decoder
    }

    private func report(now: UInt64) {
        guard now >= lastReport + 1_000_000, let session = endpoint.session else { return }
        let seconds = Double(now - lastReport) / 1_000_000
        lastReport = now
        let c = session.connection
        let mbps = Double(c.stats.bytesReceived - lastBytes) * 8 / seconds / 1_000_000
        lastBytes = c.stats.bytesReceived
        var status: [UInt8: String] = [:]
        for (stream, decoder) in decoders {
            let decoded = decoder.decoded
            let fps = Double(decoded - lastDecoded[stream, default: 0]) / seconds
            lastDecoded[stream] = decoded
            let v = session.videos[stream]?.stats ?? VideoReceiverStats()
            status[stream] = String(
                format: "%.0f fps · %.1f Mb/s · RTT %.1f ms · lost %d · keyframes %d · FEC-repaired %d · NACKed %d", fps,
                mbps, Double(c.rtt.smoothed) / 1000, v.framesLost + v.framesUndecodable, v.keyframesDelivered, v.fecRepaired,
                v.nackedFragments)
        }
        post(.stats(status))
        if now >= lastLogged + 5_000_000 {
            lastLogged = now
            for stream in status.keys.sorted() {
                log("stream \(stream): \(status[stream]!) · \(socket.dropped) datagrams dropped on purpose")
            }
        }
    }
}
