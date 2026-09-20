import CryptoKit
import LightrayCore
import LightrayCrypto

/// Demultiplexes many client sessions by `session_id`, runs the handshake, and
/// owns the parking, grace and expiry policy.
public final class HostEndpoint {
    public struct Event {
        public var sessionID: UInt32
        public var event: ConnectionEvent
    }

    private let responder: HandshakeResponder
    private let streams: [StreamDescriptor]
    private let offeredCapabilities: Capabilities
    private var baseConfig: SessionConfig
    private let engine: EngineConfig
    private let pool: BufferPool

    final class Session {
        let pairingID: UInt64
        let connection: Connection
        var parkedSince: Instant?
        init(pairingID: UInt64, connection: Connection) {
            self.pairingID = pairingID
            self.connection = connection
        }
    }

    private var sessions: [UInt32: Session] = [:]
    private var order: [UInt32] = []          // round-robin cursor over sessions
    private var cursor = 0
    private var outbox: [(bytes: [UInt8], destination: PeerAddress)] = []
    private var events = RingBuffer<Event>(capacity: 128)

    /// SESSION_UNKNOWN is rate-limited so it cannot be turned into a reflector.
    private var resetTokens: Double = 20
    private var lastResetRefill: Instant
    private let resetRate: Double = 20        // per second

    public private(set) var versionMismatches: UInt64 = 0
    public private(set) var handshakeFailures: UInt64 = 0
    public private(set) var replayedInits: UInt64 = 0
    public private(set) var sessionsEvicted: UInt64 = 0

    public init(psk: SymmetricKey, streams: [StreamDescriptor], config: SessionConfig,
                engine: EngineConfig = EngineConfig(), pool: BufferPool,
                capabilities: Capabilities = [.ltr], hostSecret: SymmetricKey = SymmetricKey(size: .bits256),
                at now: Instant = .zero) {
        self.responder = HandshakeResponder(psk: psk, hostSecret: hostSecret)
        self.streams = streams
        self.baseConfig = config
        self.engine = engine
        self.pool = pool
        self.offeredCapabilities = capabilities
        self.lastResetRefill = now
    }

    public var sessionCount: Int { sessions.count }
    public var parkedCount: Int { sessions.values.count { $0.connection.isParked } }

    public func connection(_ sessionID: UInt32) -> Connection? { sessions[sessionID]?.connection }
    public var activeSessionIDs: [UInt32] { Array(sessions.keys) }

    public func pollEvent() -> Event? { events.pop() }

    // MARK: - Receive

    public func handle(datagram: UnsafeRawBufferPointer, from source: PeerAddress, at now: Instant) {
        guard datagram.count >= 1 else { return }

        if PacketHeader.isHandshake(firstByte: datagram[0]) {
            if datagram[0] == HandshakeType.initPacket.rawValue {
                handleInit(datagram, from: source, at: now)
            }
            // RESPONSE and SESSION_UNKNOWN are host-to-client only; ignore them.
            return
        }

        guard let sessionID = PacketHeader.peekSessionID(datagram) else { return }
        guard let session = sessions[sessionID] else {
            // The client's session is gone; tell it at once so it re-handshakes
            // instead of retrying into the void.
            sendSessionUnknown(sessionID, to: source, at: now)
            return
        }
        session.connection.handle(datagram: datagram, from: source, at: now)
        drain(session, at: now)
    }

    private func handleInit(_ datagram: UnsafeRawBufferPointer, from source: PeerAddress, at now: Instant) {
        let accepted: HandshakeResponder.AcceptedInit
        do {
            accepted = try responder.receiveInit(datagram)
        } catch HandshakeError.versionMismatch {
            // Dropped silently, with a counter: a peer that disagrees about the
            // codec pinned to this version cannot be talked round.
            versionMismatches &+= 1
            return
        } catch HandshakeError.replayed {
            replayedInits &+= 1
            return
        } catch {
            handshakeFailures &+= 1
            return
        }

        var response = ResponseBody()
        // INTRA_REFRESH is reserved and never accepted: VideoToolbox has no
        // intra-refresh property, so the capability could not be honoured.
        response.acceptedCapabilities = accepted.body.capabilities
            .intersection(offeredCapabilities)
            .subtracting(.intraRefresh)
        response.streams = streams.isEmpty ? accepted.body.streams : streams
        response.maxDatagramSize = min(accepted.body.maxDatagramSize, UInt16(Wire.maxMaxDatagramSize))
        response.pipelineIdleAfterMillis = UInt32(engine.pipelineIdleAfter.millis)
        response.graceWindowMillis = UInt32(engine.graceWindow.millis)
        var config = baseConfig
        config.maxDatagramSize = response.maxDatagramSize
        response.config = config

        // Adopt a parked session the client named, if it is still here under the
        // same pairing. Same session and stats, brand-new keys.
        var sessionID: UInt32
        var adopting: Session?
        if let wanted = accepted.body.resumeSessionID,
           let existing = sessions[wanted], existing.pairingID == accepted.pairingID {
            sessionID = wanted
            adopting = existing
            response.adoptedResume = true
        } else {
            sessionID = allocateSessionID()
        }

        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: Wire.maxMaxDatagramSize, alignment: 64)
        defer { scratch.deallocate() }
        let written: HandshakeResponder.Response
        do {
            written = try responder.writeResponse(into: scratch, accepted: accepted,
                                                  sessionID: sessionID, body: response)
        } catch {
            handshakeFailures &+= 1
            return
        }
        outbox.append((Array(UnsafeRawBufferPointer(rebasing: scratch[..<written.length])), source))

        if let existing = adopting {
            existing.connection.adopt(send: written.keys.hostToClient,
                                      receive: written.keys.clientToHost,
                                      peer: source, at: now)
            existing.parkedSince = nil
            // A resume is always an IDR, whichever way the client got back.
            existing.connection.emitRefreshForOutboundVideo(at: now)
            events.push(Event(sessionID: sessionID, event: .resumed))
            drain(existing, at: now)
            return
        }

        let protection = PacketProtection(mode: .aesGCM, send: written.keys.hostToClient,
                                          receive: written.keys.clientToHost)
        let connection = Connection(role: .host, sessionID: sessionID, protection: protection,
                                    streams: response.streams, config: config,
                                    capabilities: response.acceptedCapabilities,
                                    engine: engine, peer: source, pool: pool, at: now)
        connection.expectedResetToken = written.resetToken
        connection.reconnect.handshakes &+= 1
        let session = Session(pairingID: accepted.pairingID, connection: connection)
        evictIfNeeded(at: now)
        sessions[sessionID] = session
        order.append(sessionID)
        drain(session, at: now)
    }

    private func allocateSessionID() -> UInt32 {
        var id: UInt32 = 0
        repeat {
            id = UInt32.random(in: 1...UInt32.max)
        } while sessions[id] != nil
        return id
    }

    /// Bounds the table, evicting the oldest parked session first.
    private func evictIfNeeded(at now: Instant) {
        let parked = sessions.filter { $0.value.connection.isParked }
        guard parked.count >= engine.maxParkedSessions else { return }
        let oldest = parked.min { a, b in
            (a.value.parkedSince ?? .zero) < (b.value.parkedSince ?? .zero)
        }
        if let victim = oldest {
            victim.value.connection.expire(at: now)
            drain(victim.value, at: now)
            remove(victim.key)
            sessionsEvicted &+= 1
        }
    }

    private func sendSessionUnknown(_ sessionID: UInt32, to destination: PeerAddress, at now: Instant) {
        let elapsed = (now - lastResetRefill).seconds
        if elapsed > 0 {
            resetTokens = min(resetTokens + elapsed * resetRate, resetRate)
            lastResetRefill = now
        }
        guard resetTokens >= 1 else { return }
        resetTokens -= 1
        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: 64, alignment: 16)
        defer { scratch.deallocate() }
        guard let n = try? responder.writeSessionUnknown(into: scratch, sessionID: sessionID) else { return }
        outbox.append((Array(UnsafeRawBufferPointer(rebasing: scratch[..<n])), destination))
    }

    private func remove(_ sessionID: UInt32) {
        sessions[sessionID] = nil
        if let i = order.firstIndex(of: sessionID) {
            order.remove(at: i)
            if cursor > i { cursor -= 1 }
        }
        if cursor >= order.count { cursor = 0 }
    }

    private func drain(_ session: Session, at now: Instant) {
        while let e = session.connection.pollEvent() {
            if case .parked = e { session.parkedSince = now }
            if case .resumed = e { session.parkedSince = nil }
            events.push(Event(sessionID: session.connection.sessionID, event: e))
        }
    }

    // MARK: - Timers

    /// One coarse sweep over every session: the connections park themselves on
    /// silence, and this expires the ones past their grace window. A parked
    /// session has no timer of its own, which is what makes a 30-minute window
    /// affordable.
    public func handleTimeout(at now: Instant) {
        var expired: [UInt32] = []
        for (id, session) in sessions {
            let connection = session.connection
            connection.handleTimeout(at: now)
            drain(session, at: now)      // picks up .parked, which sets parkedSince
            if connection.isParked, let since = session.parkedSince,
               now - since >= engine.graceWindow {
                connection.expire(at: now)
            }
            if connection.state == .closed { expired.append(id) }
            drain(session, at: now)
        }
        for id in expired { remove(id) }
    }

    public func nextTimeout(at now: Instant) -> Instant? {
        if !outbox.isEmpty { return now }
        var earliest: Instant?
        func consider(_ t: Instant?) {
            guard let t else { return }
            if earliest == nil || t < earliest! { earliest = t }
        }
        for (_, session) in sessions {
            consider(session.connection.nextTimeout(at: now))
            if let since = session.parkedSince, session.connection.isParked {
                consider(since + engine.graceWindow)
                let idleAt = since + engine.pipelineIdleAfter
                if idleAt > now { consider(idleAt) }
            }
        }
        return earliest
    }

    // MARK: - Transmit

    /// Handshake replies first, then a round robin over sessions so one busy
    /// client cannot starve the others.
    public func pollTransmit(into buf: UnsafeMutableRawBufferPointer, at now: Instant) -> Outgoing? {
        if !outbox.isEmpty {
            let item = outbox.removeFirst()
            guard item.bytes.count <= buf.count else { return nil }
            item.bytes.withUnsafeBytes { src in
                UnsafeMutableRawBufferPointer(rebasing: buf[..<src.count]).copyMemory(from: src)
            }
            return Outgoing(length: item.bytes.count, destination: item.destination)
        }
        guard !order.isEmpty else { return nil }
        for _ in 0..<order.count {
            let id = order[cursor % order.count]
            cursor = (cursor + 1) % order.count
            guard let session = sessions[id] else { continue }
            if let out = session.connection.pollTransmit(into: buf, at: now) {
                drain(session, at: now)
                return out
            }
        }
        return nil
    }
}
