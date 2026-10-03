import CryptoKit

public enum HostEvent: Equatable, Sendable {
    case sessionStarted(sessionID: UInt32, peer: PeerAddress)
    case sessionEnded(sessionID: UInt32, reason: String)
    /// The next frame encoded for this video stream must be a keyframe: the session started or
    /// resumed, or the client asked for one.
    case keyframeNeeded(stream: UInt8)
    /// The client asks for `display` on a video stream (0 for none). The host answers with
    /// `displaySelected`, whatever it decides.
    case displayRequested(stream: UInt8, display: UInt32, reqID: UInt32)
    case input(InputMessage)
    /// The client went silent; media stops, and capture and the encoder can stay warm.
    case paused
    case resumed
}

public struct HostConfig: Sendable {
    /// The largest datagram the host accepts; the client's proposal is lowered to it.
    public var maxDatagramSize = 1200
    /// For each video stream, parity included.
    public var bitrate = 20_000_000
    public var frameRate = 60
    /// Reed–Solomon parity as a percentage of each block's data, for clients that offer FEC; 0
    /// turns it off. At least `fecMinParity` parity fragments per block.
    public var fecPercent = 10
    public var fecMinParity = 1
    public var pauseAfterSilence: UInt64 = 2_000_000
    public var expireAfterSilence: UInt64 = 60_000_000

    public init() {}
}

public struct HostStats: Sendable {
    public init() {}

    public var versionMismatches = 0
    public var initsDiscarded = 0
    public var initsAnsweredFromCache = 0
    public var handshakesRejected = 0
    public var unknownSessions = 0
    public var sessionUnknownSent = 0
    public var otherDiscarded = 0
}

/// One client's session on the host.
public final class HostSession {
    public let connection: Connection
    /// Every video stream in the table, in table order; each is independent of the others.
    public let videoStreams: [UInt8]
    public let videos: [UInt8: VideoSender]
    public fileprivate(set) var paused = false
    /// Whether the client offered FEC and the host sends parity.
    public let fec: Bool
    /// Which stream `tick` drains first, rotated so no stream always goes last.
    fileprivate var drainOffset = 0
    /// When the RESPONSE went out, for a first round-trip sample from the client's first packet;
    /// nil once taken, or if a repeated RESPONSE made it ambiguous.
    fileprivate var responseSent: UInt64?

    init(connection: Connection, videos: [VideoSender], fec: Bool) {
        self.connection = connection
        self.fec = fec
        videoStreams = videos.map(\.stream)
        self.videos = Dictionary(uniqueKeysWithValues: videos.map { ($0.stream, $0) })
    }
}

/// The host's side of the protocol, without I/O: it answers INITs, holds one session at a time,
/// and turns the session's traffic into events. Its owner feeds it datagrams, encoded frames and
/// the time, sends what `takeOutbox` returns, and wakes it at `nextWakeup`.
public final class HostEndpoint {
    public let config: HostConfig
    public private(set) var session: HostSession?
    public private(set) var stats = HostStats()

    private let psk: (UInt64) -> Bytes?
    private let hostSecret: Bytes
    private var cache: [Bytes: (response: Bytes, time: UInt64)] = [:]
    private var cacheOrder: [Bytes] = []
    private var bucket = (tokens: 20.0, last: UInt64(0))
    private var outbox: [(Bytes, PeerAddress)] = []
    private var events: [HostEvent] = []

    static let cacheLifetime: UInt64 = 60_000_000
    static let cacheLimit = 4096

    /// `psk` finds a pairing's key; `hostSecret` keys the reset tokens and is never sent.
    public init(config: HostConfig, hostSecret: Bytes, psk: @escaping (UInt64) -> Bytes?) {
        precondition(hostSecret.count >= 32)
        self.config = config
        self.hostSecret = hostSecret
        self.psk = psk
    }

    public func takeOutbox() -> [(Bytes, PeerAddress)] {
        defer { outbox.removeAll() }
        return outbox
    }

    public func takeEvents() -> [HostEvent] {
        defer { events.removeAll() }
        return events
    }

    // MARK: Receiving

    public func receive(_ datagram: Bytes, from address: PeerAddress, now: UInt64, unixTime: UInt64) {
        guard let first = datagram.first else { return }
        if first & 0x80 == 0 {
            receiveProtected(datagram, from: address, now: now)
        } else if first == Handshake.PacketType.initiation {
            guard datagram.count >= 2, datagram[1] == Handshake.version else {
                stats.versionMismatches += 1
                return
            }
            receiveInit(datagram, from: address, now: now, unixTime: unixTime)
        } else {
            stats.otherDiscarded += 1
        }
    }

    private func receiveProtected(_ datagram: Bytes, from address: PeerAddress, now: UInt64) {
        guard datagram.count >= Packet.minimumLength, let header = ProtectedHeader(datagram) else {
            stats.otherDiscarded += 1
            return
        }
        guard let session, session.connection.sessionID == header.sessionID else {
            stats.unknownSessions += 1
            sendSessionUnknown(header.sessionID, to: address, now: now)
            return
        }
        let gap = now - min(now, session.connection.lastReceived)
        guard let inbound = session.connection.receive(datagram, header: header, from: address, now: now) else { return }
        if let sent = session.responseSent {
            // The client pings as soon as it opens the RESPONSE: one round trip.
            session.responseSent = nil
            if !session.connection.rtt.hasSample { session.connection.rtt.add(now - sent) }
        } else if gap > VideoReceiver.silence {
            // The client was silent, so its NACKs were held up too: give its frames that time back.
            for video in session.videos.values { video.extendDeadlines(by: gap) }
        }
        if session.paused {
            session.paused = false
            events.append(.resumed)
            events += session.videoStreams.map { .keyframeNeeded(stream: $0) }
        }
        for item in inbound {
            switch item {
            case .message(0, let payload):
                if case .selectDisplay(let reqID, let stream, let display) = ControlMessage(payload),
                    session.videos[stream] != nil
                {
                    events.append(.displayRequested(stream: stream, display: display, reqID: reqID))
                }
            case .message(_, let payload):
                if let message = InputMessage(payload) { events.append(.input(message)) }
            case .nack(let nack):
                session.videos[nack.stream]?.handle(nack, now: now, srtt: session.connection.rtt.smoothed)
            case .refresh(let request):
                if session.videos[request.stream]?.handle(request, now: now) == true {
                    events.append(.keyframeNeeded(stream: request.stream))
                }
            case .close:
                end(reason: "client closed the session")
                return
            case .fragment, .datagram:
                break
            }
        }
    }

    private func sendSessionUnknown(_ sessionID: UInt32, to address: PeerAddress, now: UInt64) {
        // A bucket of 20 refilled at 20 a second, shared by every destination.
        bucket.tokens = min(20, bucket.tokens + Double(now &- bucket.last) * 20 / 1_000_000)
        bucket.last = now
        guard bucket.tokens >= 1 else { return }
        bucket.tokens -= 1
        stats.sessionUnknownSent += 1
        let token = Handshake.resetToken(hostSecret: hostSecret, sessionID: sessionID)
        outbox.append((Handshake.sessionUnknown(sessionID: sessionID, token: token), address))
    }

    private func receiveInit(_ datagram: Bytes, from address: PeerAddress, now: UInt64, unixTime: UInt64) {
        let opened: OpenedInit
        do { opened = try OpenedInit.open(datagram, psk: psk) } catch {
            stats.initsDiscarded += 1
            return
        }
        // After opening, before the timestamp: a retransmitted INIT gets the same RESPONSE.
        let digest = Bytes(SHA256.hash(data: datagram))
        pruneCache(now: now)
        if let cached = cache[digest] {
            stats.initsAnsweredFromCache += 1
            session?.responseSent = nil
            outbox.append((cached.response, address))
            return
        }
        do { try opened.validate(unixTime: unixTime) } catch {
            stats.handshakesRejected += 1
            return
        }
        let proposed = opened.params
        var accepted: [StreamEntry] = []
        for entry in proposed.streamTable!.entries {
            switch (entry.kind, entry.direction, entry.streamClass) {
            case (.video, .hostToClient, .media):
                // Every one: how many displays can stream at once is for the hardware to say.
                accepted.append(entry)
            case (.input, .clientToHost, .reliable):
                accepted.append(entry)
            default:
                break  // A host may leave out streams it will not carry.
            }
        }
        guard !accepted.isEmpty else {
            stats.handshakesRejected += 1
            return
        }
        let table = StreamTable(accepted)
        let size = min(Int(proposed.maxDatagramSize!), config.maxDatagramSize)
        let fec = config.fecPercent > 0 && (proposed.capabilities ?? 0) & Capability.fec != 0
        var sessionID: UInt32
        repeat { sessionID = UInt32.random(in: 1...UInt32.max) } while sessionID == session?.connection.sessionID
        let params = HandshakeParams(
            capabilities: fec ? Capability.fec : nil, streamTable: table, maxDatagramSize: UInt16(size))
        guard
            let result = opened.respond(
                sessionID: sessionID, resetToken: Handshake.resetToken(hostSecret: hostSecret, sessionID: sessionID),
                params: params)
        else {
            stats.initsDiscarded += 1
            return
        }
        cache[digest] = (result.response, now)
        cacheOrder.append(digest)

        // One session at a time: a new handshake replaces the old session.
        if session != nil {
            if let old = session {
                old.connection.queue(.close(.goingAway))
                outbox += old.connection.flush(now: now).map { ($0, old.connection.peer) }
            }
            end(reason: "replaced by a new handshake")
        }
        let connection = Connection(
            role: .host, sessionID: sessionID, sendKey: result.sendKey, receiveKey: result.receiveKey, streams: table,
            maxDatagramSize: size, peer: address, now: now)
        let videos = table.entries.filter { $0.kind == .video && $0.direction == .hostToClient }.map {
            let video = VideoSender(stream: $0.id, bitrate: config.bitrate, frameRate: config.frameRate)
            if fec {
                video.fecPercent = config.fecPercent
                video.fecMinParity = config.fecMinParity
            }
            return video
        }
        let session = HostSession(connection: connection, videos: videos, fec: fec)
        session.responseSent = now
        self.session = session
        outbox.append((result.response, address))
        events.append(.sessionStarted(sessionID: sessionID, peer: address))
        events += session.videoStreams.map { .keyframeNeeded(stream: $0) }
    }

    private func pruneCache(now: UInt64) {
        while let oldest = cacheOrder.first,
            let entry = cache[oldest], now > entry.time + Self.cacheLifetime || cacheOrder.count > Self.cacheLimit
        {
            cache[oldest] = nil
            cacheOrder.removeFirst()
        }
    }

    // MARK: Sending

    /// Queues an encoded frame on a video stream of the current session, if it is streaming.
    public func submit(_ frame: EncodedFrame, stream: UInt8, now: UInt64) {
        guard let session, !session.paused, let video = session.videos[stream] else { return }
        video.submit(
            frame, now: now, datagramSize: session.connection.maxDatagramSize,
            budget: session.connection.latencyBudget)
    }

    /// Sends a control message on stream 0: the display list, or a stream's display.
    public func send(_ message: ControlMessage) {
        session?.connection.send(message: message.encoded, on: 0)
    }

    /// Drops what is queued on a video stream, when it stops showing a display.
    public func resetStream(_ stream: UInt8) { session?.videos[stream]?.reset() }

    public var isStreaming: Bool { session.map { !$0.paused } ?? false }

    /// Runs the session's timers and moves whatever is due into the outbox.
    public func tick(now: UInt64) {
        guard let session else { return }
        let connection = session.connection
        let silence = now > connection.lastReceived ? now - connection.lastReceived : 0
        if silence >= config.expireAfterSilence {
            end(reason: "client silent for \(silence / 1_000_000) s")
            return
        }
        if silence >= config.pauseAfterSilence, !session.paused {
            session.paused = true
            for video in session.videos.values { video.reset() }
            events.append(.paused)
        }
        // A paused session is sent nothing.
        guard !session.paused else { return }
        let peer = connection.peer
        outbox += connection.flush(now: now).map { ($0, peer) }
        // Each stream paces itself; the order they drain in rotates.
        let streams = session.videoStreams
        for i in streams.indices {
            let video = session.videos[streams[(i + session.drainOffset) % streams.count]]!
            outbox += video.drain(now: now, datagramSize: connection.maxDatagramSize) { connection.seal($0, now: now) }
                .map { ($0, peer) }
        }
        if !streams.isEmpty { session.drainOffset = (session.drainOffset + 1) % streams.count }
    }

    public func nextWakeup(now: UInt64) -> UInt64? {
        guard let session else { return nil }
        let connection = session.connection
        var wake = connection.lastReceived + config.expireAfterSilence
        guard !session.paused else { return wake }
        wake = min(wake, connection.lastReceived + config.pauseAfterSilence, connection.nextDeadline())
        for video in session.videos.values {
            guard let d = video.nextDeadline(now: now) else { continue }
            // An address still being validated may block media; poll it rather than spin.
            wake = min(wake, connection.isValidatingAddress ? max(d, now + 5_000) : d)
        }
        return wake
    }

    /// Ends the session, telling the client.
    public func close(now: UInt64, code: CloseCode = .goingAway) {
        guard let session else { return }
        session.connection.queue(.close(code))
        outbox += session.connection.flush(now: now).map { ($0, session.connection.peer) }
        end(reason: "host closed the session")
    }

    private func end(reason: String) {
        guard let session else { return }
        events.append(.sessionEnded(sessionID: session.connection.sessionID, reason: reason))
        self.session = nil
    }
}
