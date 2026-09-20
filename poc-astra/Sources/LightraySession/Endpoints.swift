import LightrayCrypto

public final class HostEndpoint {
    private let responder: HandshakeResponder
    private let secret: [UInt8]
    private let pairings: [UInt64: [UInt8]]
    private var nextID: UInt32 = 1
    private var output = RingBuffer<Transmit>(capacity: 128)
    private var notices = RingBuffer<(UInt32, ConnectionEvent)>(capacity: 512)
    private var lastReset = Instant()
    private var nextSweep = Instant(1_000_000_000)
    public private(set) var connections: [UInt32: Connection] = [:]
    public var policy: SessionPolicy
    public private(set) var rejectedHandshakes: UInt64 = 0
    public init(pairings: [UInt64: [UInt8]], secret: [UInt8], policy: SessionPolicy = .init()) throws {
        self.pairings = pairings
        self.secret = secret
        self.policy = policy
        responder = try .init(secret: secret)
    }
    public func handle(datagram: [UInt8], from: PeerAddress, at: Instant, timestamp: UInt64) {
        guard let first = datagram.first else { return }
        if first == 0x80 {
            do {
                var r = ByteReader(datagram.span.bytes)
                try r.skip(4)
                let pairing = try r.u64()
                guard let psk = pairings[pairing], connections.count < 256 else {
                    rejectedHandshakes += 1
                    return
                }
                let response = try responder.accept(datagram, psk: psk, sessionID: nextID, timestamp: timestamp, pipelineIdleAfter: policy.pipelineIdleAfter, graceWindow: policy.graceWindow)
                if let result = response.result {
                    nextID &+= 1
                    if nextID == 0 { nextID = 1 }
                    if let oldID = result.resumeSessionID, let old = connections[oldID], old.pairingID == pairing, old.state == .parked { connections.removeValue(forKey: oldID) }
                    connections[result.sessionID] = .init(result: result, role: .host, peer: from, at: at, policy: policy)
                }
                _ = output.append(.init(bytes: response.packet, peer: from))
            } catch { rejectedHandshakes += 1 }
            return
        }
        guard first & 0x80 == 0, datagram.count >= 32 else { return }
        do {
            var r = ByteReader(datagram.span.bytes)
            let header = try PacketHeader.decode(&r)
            if let connection = connections[header.sessionID] {
                connection.handle(datagram: datagram, from: from, at: at)
            } else if at.elapsed(since: lastReset) >= 100_000_000 {
                lastReset = at
                var w = ByteWriter()
                w.put(UInt8(0x82))
                w.put(header.sessionID)
                w.bytes += resetToken(secret: secret, sessionID: header.sessionID)
                _ = output.append(.init(bytes: w.bytes, peer: from))
            }
        } catch { rejectedHandshakes += 1 }
    }
    public func nextTimeout() -> Instant { min(nextSweep, connections.values.compactMap { $0.nextTimeout() }.min() ?? nextSweep) }
    public func handleTimeout(at: Instant) {
        nextSweep = at.advanced(by: 1_000_000_000)
        for (id, connection) in connections {
            connection.handleTimeout(at: at)
            connection.sweepParked(at: at)
            if connection.state == .closed {
                while let event = connection.pollEvent() { _ = notices.append((id, event)) }
                connections.removeValue(forKey: id)
            }
        }
        let parked = connections.values.filter { $0.state == .parked }.sorted { ($0.parkedSince ?? .init()) < ($1.parkedSince ?? .init()) }
        for connection in parked.prefix(max(0, parked.count - policy.maxParkedSessions)) {
            _ = notices.append((connection.sessionID, .expired))
            connections.removeValue(forKey: connection.sessionID)
        }
    }
    public func pollTransmit(at: Instant) -> Transmit? {
        if let packet = output.popFirst() { return packet }
        for connection in connections.values { if let packet = connection.pollTransmit(at: at) { return packet } }
        return nil
    }
    public func pollEvent() -> (UInt32, ConnectionEvent)? {
        if let notice = notices.popFirst() { return notice }
        for (id, connection) in connections { if let event = connection.pollEvent() { return (id, event) } }
        return nil
    }
    public func systemSleep(at: Instant) {
        for connection in connections.values { do { try connection.close(at: at) } catch { _ = notices.append((connection.sessionID, .error(String(describing: error)))) } }
        connections.removeAll()
    }
}
public final class ClientEndpoint {
    private let pairingID: UInt64
    private let psk: [UInt8]
    private var handshake: HandshakeInitiator?
    private var initial: [UInt8] = []
    private var nextRetry = Instant()
    private var attempts = 0
    private var output = RingBuffer<Transmit>(capacity: 64)
    public let peer: PeerAddress
    public private(set) var connection: Connection?
    public init(peer: PeerAddress, pairingID: UInt64, psk: [UInt8]) {
        self.peer = peer
        self.pairingID = pairingID
        self.psk = psk
    }
    public func connect(configuration: Configuration = .init(), at: Instant, timestamp: UInt64) throws {
        let handshake = try HandshakeInitiator(pairingID: pairingID, psk: psk)
        initial = try handshake.start(configuration: configuration, timestamp: timestamp, resumeSessionID: connection?.sessionID)
        self.handshake = handshake
        connection = nil
        attempts = 0
        nextRetry = at.advanced(by: 100_000_000)
        _ = output.append(.init(bytes: initial, peer: peer))
    }
    public func handle(datagram: [UInt8], from: PeerAddress, at: Instant) {
        if datagram.first == 0x81, let handshake {
            do {
                let result = try handshake.finish(datagram)
                connection = .init(result: result, role: .client, peer: from, at: at)
                self.handshake = nil
            } catch { return }
        } else {
            connection?.handle(datagram: datagram, from: from, at: at)
        }
    }
    public func nextTimeout() -> Instant? { handshake != nil && attempts < 8 ? nextRetry : connection?.nextTimeout() }
    public func handleTimeout(at: Instant) {
        if handshake != nil, at >= nextRetry, attempts < 8 {
            attempts += 1
            nextRetry = at.advanced(by: min(2_000_000_000, 100_000_000 << attempts))
            _ = output.append(.init(bytes: initial, peer: peer))
        }
        connection?.handleTimeout(at: at)
    }
    public func pollTransmit(at: Instant) -> Transmit? { output.popFirst() ?? connection?.pollTransmit(at: at) }
    public func pollEvent() -> ConnectionEvent? { connection?.pollEvent() }
}
