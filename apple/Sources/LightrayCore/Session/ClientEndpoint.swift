public enum ClientEvent: Sendable {
    case connecting
    /// `videoStreams` lists the video streams the host accepted, in table order.
    case connected(sessionID: UInt32, maxDatagramSize: Int, videoStreams: [UInt8])
    case frame(stream: UInt8, DeliveredFrame)
    /// The host's displays, replacing any list sent before.
    case displays([DisplayInfo])
    /// The display a video stream now shows; 0 for none.
    case streamDisplay(stream: UInt8, display: UInt32)
    /// The session is gone; the client starts a new handshake on its own.
    case disconnected(reason: String)
}

public struct ClientConfig: Sendable {
    public var pairingID: UInt64
    public var psk: Bytes
    public var host: PeerAddress
    public var maxDatagramSize = 1200
    /// Offer Reed–Solomon FEC; the host decides whether to send parity.
    public var offerFEC = true
    /// How many displays the client may show at once: one video stream each.
    public var videoStreamCount = 4
    /// Video stream 1, a reliable input stream for the keyboard (4) and one for the pointer (5),
    /// and any further video streams from 16 up.
    public var streams: StreamTable {
        var entries = [
            StreamEntry(id: 1, kind: .video, direction: .hostToClient, streamClass: .media),
            StreamEntry(id: 4, kind: .input, direction: .clientToHost, streamClass: .reliable),
            StreamEntry(id: 5, kind: .input, direction: .clientToHost, streamClass: .reliable),
        ]
        for i in 0..<max(0, min(videoStreamCount, 30) - 1) {
            entries.append(StreamEntry(id: UInt8(16 + i), kind: .video, direction: .hostToClient, streamClass: .media))
        }
        return StreamTable(entries)
    }
    /// With nothing from the host for this long, start over.
    public var silenceTimeout: UInt64 = 5_000_000
    public var retryDelay: UInt64 = 1_000_000

    public init(pairingID: UInt64, psk: Bytes, host: PeerAddress) {
        self.pairingID = pairingID
        self.psk = psk
        self.host = host
    }
}

/// The client's session: its connection, the video it receives and the input it sends.
public final class ClientSession {
    public let connection: Connection
    /// Every video stream the host accepted, in table order; each is independent of the others.
    public let videoStreams: [UInt8]
    public let videos: [UInt8: VideoReceiver]
    /// Whether the host accepted FEC and sends parity.
    public let fec: Bool
    let resetToken: Bytes
    var nextRequest: UInt32 = 1
    let keyboardStream: UInt8?
    let pointerStream: UInt8?
    var pendingMotion: InputMessage?
    var lastMotion: UInt64 = 0

    static let mergeInterval: UInt64 = 1_000

    init(connection: Connection, resetToken: Bytes, fec: Bool) {
        self.connection = connection
        self.resetToken = resetToken
        self.fec = fec
        videoStreams = connection.streams.entries.filter { $0.kind == .video && $0.direction == .hostToClient }.map(\.id)
        videos = Dictionary(uniqueKeysWithValues: videoStreams.map { ($0, VideoReceiver(stream: $0, sharedBudget: connection.memoryBudget)) })
        let input = connection.streams.entries.filter { $0.kind == .input && $0.direction == .clientToHost }
        keyboardStream = input.first?.id
        pointerStream = input.dropFirst().first?.id ?? input.first?.id
    }
}

/// The client's side of the protocol, without I/O: the handshake with its retransmissions, the
/// session once it exists, and starting over when the host goes away.
public final class ClientEndpoint {
    public let config: ClientConfig
    public private(set) var session: ClientSession?
    private let unixTime: () -> UInt64

    private enum State {
        case idle
        case handshaking(Handshaking)
        case connected
        case waiting(until: UInt64)
    }

    private struct Handshaking {
        let handshake: ClientHandshake
        let firstSent: UInt64
        var sends = 1
        var nextSend: UInt64
        var early: [Bytes] = []
    }

    private var state = State.idle
    private var outbox: [OutboundDatagram] = []
    private var events: [ClientEvent] = []

    static let maxSends = 8
    static let earlyBufferLimit = 64

    public init(config: ClientConfig, unixTime: @escaping () -> UInt64) {
        self.config = config
        self.unixTime = unixTime
    }

    public struct OutboundDatagram: Sendable {
        public let bytes: Bytes
        public let destination: PeerAddress
    }

    /// Transport adapters must preserve each destination, including after session teardown.
    public func takeOutboundDatagrams() -> [OutboundDatagram] {
        defer { outbox.removeAll() }
        return outbox
    }

    /// Byte-only compatibility helper for simulations with a fixed route.
    public func takeOutbox() -> [Bytes] { takeOutboundDatagrams().map(\.bytes) }

    public func takeEvents() -> [ClientEvent] {
        defer { events.removeAll() }
        return events
    }

    public var isConnected: Bool { if case .connected = state { true } else { false } }

    // MARK: The handshake

    public func start(now: UInt64) {
        let params = HandshakeParams(
            timestamp: unixTime(), capabilities: config.offerFEC ? Capability.fec : nil, streamTable: config.streams,
            maxDatagramSize: UInt16(config.maxDatagramSize))
        let handshake = ClientHandshake(psk: config.psk, pairingID: config.pairingID, params: params)
        state = .handshaking(Handshaking(handshake: handshake, firstSent: now, nextSend: now + 100_000))
        session = nil
        outbox.append(OutboundDatagram(bytes: handshake.datagram, destination: config.host))
        events.append(.connecting)
    }

    private func restart(reason: String, now: UInt64, immediately: Bool) {
        session = nil
        events.append(.disconnected(reason: reason))
        if immediately {
            start(now: now)
        } else {
            state = .waiting(until: now + config.retryDelay)
        }
    }

    // MARK: Receiving

    public func receive(_ datagram: Bytes, from address: PeerAddress, now: UInt64) {
        guard let first = datagram.first else { return }
        switch first {
        case Handshake.PacketType.response:
            receiveResponse(datagram, now: now)
        case Handshake.PacketType.sessionUnknown:
            guard let session, datagram.count == Handshake.sessionUnknownLength, datagram[1] == Handshake.version else {
                return
            }
            var r = ByteReader(datagram)
            _ = try! r.take(2)
            guard try! r.u32() == session.connection.sessionID, constantTimeEqual(Bytes(r.rest()), session.resetToken)
            else { return }
            restart(reason: "the host no longer holds the session", now: now, immediately: true)
        case 0x00...0x7f:
            if case .handshaking(var h) = state {
                // The host may send before its RESPONSE arrives; keep a few to open afterwards.
                if address == config.host, h.early.count < Self.earlyBufferLimit {
                    h.early.append(datagram)
                    state = .handshaking(h)
                }
                return
            }
            receiveProtected(datagram, from: address, now: now)
        default:
            break
        }
    }

    private func receiveResponse(_ datagram: Bytes, now: UInt64) {
        guard case .handshaking(let h) = state else { return }
        let result: ClientHandshake.Result
        do {
            guard let opened = try h.handshake.open(datagram) else { return }
            result = opened
        } catch {
            restart(reason: "handshake rejected: \(error)", now: now, immediately: false)
            return
        }
        let connection = Connection(
            role: .client, sessionID: result.sessionID, sendKey: result.sendKey, receiveKey: result.receiveKey,
            streams: result.params.streamTable!, maxDatagramSize: Int(result.params.maxDatagramSize!),
            peer: config.host, now: now)
        // An unambiguous sample: the INIT was sent once.
        if h.sends == 1 { connection.rtt.add(now - h.firstSent) }
        // Heard at once, the PING gives the host its first round-trip sample.
        connection.requestPing()
        session = ClientSession(
            connection: connection, resetToken: result.resetToken,
            fec: (result.params.capabilities ?? 0) & Capability.fec != 0)
        state = .connected
        events.append(.connected(
            sessionID: result.sessionID, maxDatagramSize: connection.maxDatagramSize,
            videoStreams: session!.videoStreams))
        for early in h.early { receiveProtected(early, from: config.host, now: now) }
    }

    private func receiveProtected(_ datagram: Bytes, from address: PeerAddress, now: UInt64) {
        guard let session, datagram.count >= Packet.minimumLength, let header = ProtectedHeader(datagram),
            header.sessionID == session.connection.sessionID
        else { return }
        let gap = now - min(now, session.connection.lastReceived)
        guard let inbound = session.connection.receive(datagram, header: header, from: address, now: now) else { return }
        // Back from a silence: what arrives now was held up, not lost, and open frames get the time back.
        if gap > VideoReceiver.silence {
            for video in session.videos.values { video.linkResumed(after: gap) }
        }
        for item in inbound {
            switch item {
            case .fragment(let fragment):
                session.videos[fragment.stream]?.receive(fragment, now: now, budget: session.connection.latencyBudget)
            case .message(0, let payload):
                switch ControlMessage(payload) {
                case .displays(let list): events.append(.displays(list))
                case .displaySelected(_, let stream, let display), .streamDisplay(let stream, let display):
                    events.append(.streamDisplay(stream: stream, display: display))
                case .selectDisplay, nil: break
                }
            case .close(let code):
                restart(reason: "the host closed the session (\(code))", now: now, immediately: false)
                return
            case .message, .datagram, .nack, .refresh:
                break
            }
        }
        collectFrames(session)
    }

    private func collectFrames(_ session: ClientSession) {
        for stream in session.videoStreams {
            events += session.videos[stream]!.takeFrames().map { ClientEvent.frame(stream: stream, $0) }
        }
    }

    // MARK: Input and decoder reports

    /// Queues an input message. Pointer motion waits up to the merge interval, replaced by newer
    /// motion; anything else on the pointer stream sends the waiting motion first.
    /// False means the event was not accepted; reliable input overflow ends the session so the host resets held input.
    @discardableResult
    public func send(_ message: InputMessage, now: UInt64) -> Bool {
        guard let session, isConnected else { return false }
        switch message {
        case .key:
            guard let stream = session.keyboardStream else { return false }
            guard session.connection.send(message: message.encoded, on: stream) else {
                inputOverflow(session, now: now)
                return false
            }
        case .pointer:
            guard session.pointerStream != nil else { return false }
            session.pendingMotion = message
            _ = flushMotion(session, now: now, force: false)
        case .button, .scroll:
            guard let stream = session.pointerStream else { return false }
            guard flushMotion(session, now: now, force: true), session.connection.send(message: message.encoded, on: stream) else {
                inputOverflow(session, now: now)
                return false
            }
        }
        return true
    }

    private func flushMotion(_ session: ClientSession, now: UInt64, force: Bool) -> Bool {
        guard let motion = session.pendingMotion else { return true }
        guard let stream = session.pointerStream else { return false }
        guard force || now >= session.lastMotion + ClientSession.mergeInterval else { return true }
        // Retain a refused position, but throttle retries to avoid an immediate-wakeup loop.
        session.lastMotion = now
        guard session.connection.send(message: motion.encoded, on: stream) else { return false }
        session.pendingMotion = nil
        return true
    }

    private func inputOverflow(_ session: ClientSession, now: UInt64) {
        // Do not flush stale input on overflow; CLOSE, a replacement handshake, or silence releases it on the host.
        outbox.removeAll()
        if let datagram = session.connection.seal(Chunk.close(.appRequest).encoded, now: now) { outbox.append(OutboundDatagram(bytes: datagram, destination: session.connection.peer)) }
        restart(reason: "reliable input queue full; resetting the session", now: now, immediately: false)
    }

    public func decoded(stream: UInt8, frameID: UInt32, isKeyframe: Bool) {
        session?.videos[stream]?.decoded(frameID: frameID, isKeyframe: isKeyframe)
    }

    public func decoderFailed(stream: UInt8, frameID: UInt32) {
        session?.videos[stream]?.decoderFailed(frameID: frameID)
    }

    /// Asks the host to show `display` on a video stream, 0 for nothing. The answer arrives as
    /// `streamDisplay`.
    public func selectDisplay(_ display: UInt32, on stream: UInt8) {
        guard let session, isConnected, session.videos[stream] != nil else { return }
        let message = ControlMessage.selectDisplay(reqID: session.nextRequest, stream: stream, display: display)
        session.nextRequest &+= 1
        session.connection.send(message: message.encoded, on: 0)
    }

    // MARK: Timers

    public func tick(now: UInt64) {
        switch state {
        case .idle:
            return
        case .waiting(let until):
            if now >= until { start(now: now) }
        case .handshaking(var h):
            if h.sends >= Self.maxSends {
                if now >= h.nextSend { restart(reason: "no response from the host", now: now, immediately: false) }
            } else if now >= h.nextSend {
                outbox.append(OutboundDatagram(bytes: h.handshake.datagram, destination: config.host))
                h.sends += 1
                // 100 ms, doubling to at most 2 s; the last send is followed by 2 s of waiting.
                h.nextSend = now + (h.sends == Self.maxSends ? 2_000_000 : min(100_000 << UInt64(h.sends - 1), 2_000_000))
                state = .handshaking(h)
            }
        case .connected:
            guard let session else { return }
            let connection = session.connection
            if now > connection.lastReceived + config.silenceTimeout {
                restart(reason: "nothing from the host for \(config.silenceTimeout / 1_000_000) s", now: now, immediately: true)
                return
            }
            _ = flushMotion(session, now: now, force: false)
            for stream in session.videoStreams {
                for chunk in session.videos[stream]!.poll(
                    now: now, srtt: connection.rtt.smoothed, budget: connection.latencyBudget,
                    lastHeard: connection.lastReceived)
                {
                    connection.queue(chunk)
                }
            }
            collectFrames(session)
            outbox += connection.flush(now: now).map { OutboundDatagram(bytes: $0, destination: connection.peer) }
        }
    }

    public func nextWakeup(now: UInt64) -> UInt64? {
        switch state {
        case .idle: return nil
        case .waiting(let until): return until
        case .handshaking(let h): return h.nextSend
        case .connected:
            guard let session else { return nil }
            let connection = session.connection
            var wake = min(connection.lastReceived + config.silenceTimeout, connection.nextDeadline())
            if session.pendingMotion != nil { wake = min(wake, session.lastMotion + ClientSession.mergeInterval) }
            for video in session.videos.values {
                if let d = video.nextDeadline(now: now, srtt: connection.rtt.smoothed, lastHeard: connection.lastReceived) {
                    wake = min(wake, d)
                }
            }
            return wake
        }
    }

    /// Ends the session, telling the host, and stops.
    public func close(now: UInt64) {
        if let session, isConnected {
            session.connection.queue(.close(.appRequest))
            outbox += session.connection.flush(now: now).map { OutboundDatagram(bytes: $0, destination: session.connection.peer) }
        }
        session = nil
        state = .idle
    }
}
