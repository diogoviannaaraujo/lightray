import CryptoKit
import LightrayCore
import LightrayCrypto

/// The client side: one handshake, one session, and the resume path.
public final class ClientEndpoint {
    public enum Phase: String, Sendable {
        case idle
        case handshaking
        case connected
        /// The session is gone; the app should re-handshake.
        case lost
        case closed
    }

    private let psk: SymmetricKey
    public let pairingID: UInt64
    private let streams: [StreamDescriptor]
    private var baseConfig: SessionConfig
    private let engine: EngineConfig
    private let pool: BufferPool
    private let capabilities: Capabilities

    public private(set) var phase: Phase = .idle
    public private(set) var connection: Connection?
    public private(set) var host: PeerAddress = PeerAddress()

    private var initiator: HandshakeInitiator?
    private var initDueAt: Instant?
    private var initBackoff: Interval
    private var resumeSessionID: UInt32?
    private var handshakeStartedAt: Instant = .zero
    private var queuedReliable: [(UInt8, [UInt8])] = []
    private var events = RingBuffer<ConnectionEvent>(capacity: 64)

    /// Set when the runtime must replace the socket before the next send: a
    /// resume needs a new source port so the host sees a rebind, and a socket
    /// error or a path change needs one because the old socket is suspect.
    public private(set) var wantsFreshSocket = false

    public private(set) var reconnect = ReconnectStats()
    public private(set) var log = EventLog()

    public init(psk: SymmetricKey, pairingID: UInt64, streams: [StreamDescriptor],
                config: SessionConfig, engine: EngineConfig = EngineConfig(), pool: BufferPool,
                capabilities: Capabilities = [.ltr]) {
        self.psk = psk
        self.pairingID = pairingID
        self.streams = streams
        self.baseConfig = config
        self.engine = engine
        self.pool = pool
        self.capabilities = capabilities
        self.initBackoff = engine.handshakeRetryInitial
    }

    public func pollEvent() -> ConnectionEvent? {
        if let e = events.pop() { return e }
        guard let connection else { return nil }
        let e = connection.pollEvent()
        if case .sessionLost = e {
            phase = .lost
            resumeSessionID = connection.sessionID
            self.connection = nil
        }
        if case .closed = e { phase = .closed }
        return e
    }

    public func acknowledgeFreshSocket() { wantsFreshSocket = false }

    // MARK: - Connect

    /// Starts a handshake. `resuming` asks the host to adopt a session it may
    /// still have parked under this pairing, which costs one round trip and an
    /// IDR instead of re-pairing.
    public func connect(to destination: PeerAddress, at now: Instant, resuming: UInt32? = nil) {
        host = destination
        var body = InitBody()
        body.capabilities = capabilities
        body.streams = streams
        body.maxDatagramSize = baseConfig.maxDatagramSize
        body.clientTimestamp = now.nanos / 1000
        body.resumeSessionID = resuming ?? resumeSessionID
        body.config = baseConfig
        initiator = HandshakeInitiator(psk: psk, pairingID: pairingID, body: body)
        phase = .handshaking
        handshakeStartedAt = now
        initBackoff = engine.handshakeRetryInitial
        initDueAt = now
        reconnect.handshakes &+= 1
        log.record(.handshake, at: now)
    }

    /// Re-handshakes after the host said the session is unknown.
    public func reHandshake(at now: Instant) {
        connect(to: host, at: now, resuming: resumeSessionID)
    }

    // MARK: - Receive

    public func handle(datagram: UnsafeRawBufferPointer, from source: PeerAddress, at now: Instant) {
        guard datagram.count >= 1 else { return }

        if PacketHeader.isHandshake(firstByte: datagram[0]) {
            switch datagram[0] {
            case HandshakeType.response.rawValue:
                acceptResponse(datagram, from: source, at: now)
            case HandshakeType.sessionUnknown.rawValue:
                if let connection {
                    connection.handle(datagram: datagram, from: source, at: now)
                } else if phase == .handshaking {
                    // The session we hoped to resume is gone; start clean.
                    resumeSessionID = nil
                    connect(to: host, at: now)
                }
            default:
                break
            }
            return
        }
        connection?.handle(datagram: datagram, from: source, at: now)
    }

    private func acceptResponse(_ datagram: UnsafeRawBufferPointer, from source: PeerAddress,
                                at now: Instant) {
        guard phase == .handshaking, let initiator else { return }
        let accepted: HandshakeInitiator.Accepted
        do {
            accepted = try initiator.receiveResponse(datagram)
        } catch {
            return   // dropped silently: a forged or stale RESPONSE proves nothing
        }
        var config = accepted.body.config
        config.maxDatagramSize = accepted.body.maxDatagramSize
        let protection = PacketProtection(mode: .aesGCM, send: accepted.keys.clientToHost,
                                          receive: accepted.keys.hostToClient)
        let connection = Connection(role: .client, sessionID: accepted.sessionID, protection: protection,
                                    streams: accepted.body.streams.isEmpty ? streams : accepted.body.streams,
                                    config: config, capabilities: accepted.body.acceptedCapabilities,
                                    engine: engine, peer: source, pool: pool, at: now)
        connection.expectedResetToken = accepted.body.resetToken
        self.connection = connection
        for (stream, bytes) in queuedReliable { connection.sendReliable(bytes, stream: stream) }
        queuedReliable.removeAll(keepingCapacity: false)
        self.initiator = nil
        self.initDueAt = nil
        self.resumeSessionID = accepted.sessionID
        phase = .connected
        log.record(accepted.body.adoptedResume ? .adopted : .established, at: now,
                   detail: accepted.sessionID)
        if accepted.body.adoptedResume { reconnect.handshakesAdopted &+= 1 }
    }

    // MARK: - App commands

    public func submit(_ frame: EncodedFrame, at now: Instant) { connection?.submit(frame, at: now) }

    /// Reliable sends made before the handshake finishes are queued, not
    /// dropped: an app that starts sending input straight away should not have
    /// to know when the RESPONSE landed.
    public func sendReliable(_ bytes: [UInt8], stream: UInt8 = 0) {
        guard let connection else {
            queuedReliable.append((stream, bytes))
            return
        }
        connection.sendReliable(bytes, stream: stream)
    }

    @discardableResult
    public func reconfigure(_ body: ControlBody) -> UInt32? { connection?.reconfigure(body) }

    public func reportDecoded(stream: UInt8, frameID: UInt32, at now: Instant) {
        connection?.reportDecoded(stream: stream, frameID: frameID, at: now)
    }

    /// The app decides what counts as going idle: on macOS, screen lock or the
    /// user stepping away from the stream. System sleep is not a park — a lid
    /// close closes the session and re-handshakes on wake.
    public func park(at now: Instant) {
        connection?.requestPark(at: now)
        reconnect.parks &+= 1
    }

    /// Recreates the socket and sends RESUME, repeated with backoff until STATE
    /// arrives.
    public func resume(decoderLost: Bool, at now: Instant) {
        wantsFreshSocket = true
        connection?.requestResume(decoderLost: decoderLost, at: now)
        reconnect.resumes &+= 1
        log.record(.resumed, at: now)
    }

    /// Called by the runtime on a socket error or an `NWPathMonitor` path change.
    public func pathChanged(at now: Instant) {
        guard phase == .connected else { return }
        resume(decoderLost: false, at: now)
    }

    public func close(at now: Instant) {
        connection?.close(code: .appRequest, at: now)
    }

    // MARK: - Timers and transmit

    public func handleTimeout(at now: Instant) {
        // The INIT's retry schedule is advanced when the INIT is actually
        // written, not here: a timeout that fires first would otherwise push the
        // packet into the future and nothing would ever go out.
        connection?.handleTimeout(at: now)
    }

    public func nextTimeout(at now: Instant) -> Instant? {
        var earliest: Instant?
        if phase == .handshaking { earliest = initDueAt }
        if let t = connection?.nextTimeout(at: now) {
            if earliest == nil || t < earliest! { earliest = t }
        }
        return earliest
    }

    public func pollTransmit(into buf: UnsafeMutableRawBufferPointer, at now: Instant) -> Outgoing? {
        if phase == .handshaking, let initiator, let due = initDueAt, now >= due {
            // The INIT is padded to max_datagram_size, which both limits
            // amplification and proves the path MTU.
            guard let length = try? initiator.writeInit(into: buf,
                                                        maxDatagramSize: Int(baseConfig.maxDatagramSize))
            else { return nil }
            initDueAt = now + initBackoff
            initBackoff = Interval(nanos: min(initBackoff.nanos * 2, engine.handshakeRetryMax.nanos))
            return Outgoing(length: length, destination: host)
        }
        return connection?.pollTransmit(into: buf, at: now)
    }

    public func snapshot() -> StatsSnapshot {
        var s = connection?.snapshot() ?? StatsSnapshot()
        if connection == nil {
            s.state = phase.rawValue
            s.timeline = log.events
        }
        s.reconnect.handshakes = reconnect.handshakes
        s.reconnect.handshakesAdopted = reconnect.handshakesAdopted
        return s
    }
}
