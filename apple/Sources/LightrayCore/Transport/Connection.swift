/// A UDP address, as the transport compares it: rebinding cares whether the IP changed or only
/// the port.
public struct PeerAddress: Hashable, Sendable, CustomStringConvertible {
    /// 4 bytes for IPv4, 16 for IPv6.
    public var ip: Bytes
    public var port: UInt16

    public init(ip: Bytes, port: UInt16) {
        self.ip = ip
        self.port = port
    }

    public var description: String {
        if ip.count == 4 { return ip.map(String.init).joined(separator: ".") + ":\(port)" }
        var groups: [String] = []
        for i in stride(from: 0, to: ip.count, by: 2) { groups.append(String(UInt16(ip[i]) << 8 | UInt16(ip[i + 1]), radix: 16)) }
        return "[" + groups.joined(separator: ":") + "]:\(port)"
    }
}

/// Smoothed round-trip time in microseconds, RFC 6298.
public struct RTTEstimator: Sendable {
    public private(set) var smoothed: UInt64 = 30_000
    public private(set) var variation: UInt64 = 15_000
    public private(set) var latest: UInt64 = 0
    public private(set) var minimum: UInt64 = .max
    public private(set) var hasSample = false

    public mutating func add(_ sample: UInt64) {
        latest = sample
        minimum = min(minimum, sample)
        if !hasSample {
            smoothed = sample
            variation = sample / 2
            hasSample = true
        } else {
            let difference = smoothed > sample ? smoothed - sample : sample - smoothed
            variation = (3 * variation + difference) / 4
            smoothed = (7 * smoothed + sample) / 8
        }
    }
}

/// Counters an operator reads to diagnose a link that is nearly working.
public struct ConnectionStats: Sendable {
    public init() {}

    public var packetsSent = 0
    public var bytesSent = 0
    public var packetsReceived = 0
    public var bytesReceived = 0
    public var authenticationFailures = 0
    public var replays = 0
    public var staleRebinds = 0
    public var rebinds = 0
    public var malformedChunks = 0
    public var streamViolations = 0
    public var blockedByValidation = 0
    /// From the peer's FEEDBACK: our packets it reported received and missing.
    public var reportedReceived = 0
    public var reportedLost = 0
}

/// What the connection hands to the session above it.
public enum Inbound: Equatable, Sendable {
    case fragment(MediaFragment)
    case message(stream: UInt8, payload: Bytes)
    case datagram(stream: UInt8, payload: Bytes)
    case nack(Nack)
    case refresh(RefreshRequest)
    case close(CloseCode)
}

/// One session's transport, the same at both ends: keys, packet numbers, the replay window, the
/// peer address, feedback, round-trip time, reliable streams and keepalive. It performs no I/O;
/// its owner feeds it datagrams and the time, and sends what it returns.
public final class Connection {
    public enum Role: Sendable { case host, client }

    public let role: Role
    public let sessionID: UInt32
    public let streams: StreamTable
    public private(set) var maxDatagramSize: Int
    public private(set) var peer: PeerAddress
    public var rtt = RTTEstimator()
    public var stats = ConnectionStats()
    public private(set) var lastReceived: UInt64
    public private(set) var lastSent: UInt64

    private let sendKey: TrafficKey
    private let receiveKey: TrafficKey
    private var nextPacketNumber: UInt64 = 0
    private var replay = ReplayWindow()

    // Send times, for round-trip samples from FEEDBACK.
    private static let sentLogSize = 8192
    private var sentLog = [(pn: UInt64, time: UInt64)](repeating: (.max, 0), count: Connection.sentLogSize)

    // Arrivals not yet reported, and the packet number below which nothing is reported again.
    private var arrivals: [(pn: UInt64, time: UInt64)] = []
    private var reportedBelow: UInt64 = 0
    private var lastFeedback: UInt64 = 0
    /// Whether an unreported arrival carried something other than FEEDBACK, PONG or PADDING.
    /// Only those are reported promptly, so that two ends exchanging reports do not report each
    /// other's reports forever; the rest wait for `idleFeedbackInterval`.
    private var elicited = false
    private var pendingAcks: [ReliableAck] = []
    private var ackDue: UInt64?
    public static let feedbackInterval: UInt64 = 20_000
    public static let idleFeedbackInterval: UInt64 = 200_000
    static let ackDelay: UInt64 = 2_000

    private var senders: [UInt8: ReliableSender] = [:]
    private var receivers: [UInt8: ReliableReceiver] = [:]
    private var control: [Bytes] = []
    private var pongs: [(id: UInt32, arrival: UInt64)] = []
    private var pings: [UInt32: UInt64] = [:]
    private var nextPingID: UInt32 = 0
    private var pingWanted = false
    public static let keepaliveInterval: UInt64 = 250_000

    /// After a rebind to a new IP address: what that address has sent us, what we have sent it,
    /// and the first packet number sent there, which a FEEDBACK must report to validate it.
    private struct Validation {
        var received: Int
        var sent = 0
        let firstPacket: UInt64
    }
    private var validation: Validation?
    public var isValidatingAddress: Bool { validation != nil }

    public init(
        role: Role, sessionID: UInt32, sendKey: Bytes, receiveKey: Bytes, streams: StreamTable,
        maxDatagramSize: Int, peer: PeerAddress, now: UInt64
    ) {
        self.role = role
        self.sessionID = sessionID
        self.sendKey = TrafficKey(sendKey)
        self.receiveKey = TrafficKey(receiveKey)
        self.streams = streams
        self.maxDatagramSize = maxDatagramSize
        self.peer = peer
        lastReceived = now
        lastSent = now
        for entry in [StreamEntry.control] + streams.entries where entry.streamClass == .reliable {
            if sends(entry) { senders[entry.id] = ReliableSender(stream: entry.id) }
            if receives(entry) { receivers[entry.id] = ReliableReceiver(stream: entry.id) }
        }
    }

    /// Whether this end sends a stream's data.
    public func sends(_ entry: StreamEntry) -> Bool {
        entry.direction == .bidirectional || entry.direction == (role == .host ? .hostToClient : .clientToHost)
    }

    public func receives(_ entry: StreamEntry) -> Bool {
        entry.direction == .bidirectional || entry.direction == (role == .host ? .clientToHost : .hostToClient)
    }

    // MARK: Receiving

    /// Opens a datagram already matched to this session. Nil means it was discarded without
    /// changing any state.
    public func receive(_ datagram: Bytes, header: ProtectedHeader, from address: PeerAddress, now: UInt64) -> [Inbound]? {
        let pn = Packet.reconstruct(expected: replay.expected, transportSeq: header.transportSeq)
        guard replay.accepts(pn) else {
            stats.replays += 1
            return nil
        }
        guard let body = Packet.open(datagram, packetNumber: pn, key: receiveKey) else {
            stats.authenticationFailures += 1
            return nil
        }
        if address != peer {
            // Rebind only on the strictly newest packet: a replayed copy from elsewhere never is.
            if let highest = replay.highest, pn <= highest {
                stats.staleRebinds += 1
                return nil
            }
            if address.ip != peer.ip {
                validation = Validation(received: 0, firstPacket: nextPacketNumber)
                // Spend the allowance on something small the peer will report at once.
                pingWanted = true
            }
            peer = address
            stats.rebinds += 1
        }
        replay.record(pn)
        validation?.received += datagram.count
        lastReceived = now
        stats.packetsReceived += 1
        stats.bytesReceived += datagram.count
        let parsed = Chunk.parse(body)
        stats.malformedChunks += parsed.malformed
        if pn >= reportedBelow {
            arrivals.append((pn, now))
            if parsed.chunks.contains(where: { chunk in
                switch chunk {
                case .feedback, .pong, .padding: false
                default: true
                }
            }) { elicited = true }
        }
        var inbound: [Inbound] = []
        for chunk in parsed.chunks {
            switch chunk {
            case .padding, .unknown, .frameAck:
                break
            case .feedback(let feedback):
                handle(feedback, reporterSendTime: header.sendTimeMicros, now: now)
            case .ping(let id):
                pongs.append((id, now))
            case .pong(let id, let hold):
                if let sent = pings.removeValue(forKey: id), now > sent + UInt64(hold) {
                    rtt.add(now - sent - UInt64(hold))
                }
            case .close(let code):
                inbound.append(.close(code))
            case .reliable(let segment):
                guard let entry = checkData(segment.stream, .reliable), receives(entry),
                    let receiver = receivers[segment.stream]
                else { continue }
                if case .accepted(let ack, let deliver) = receiver.receive(segment) {
                    if ack { acknowledge(ReliableAck(stream: segment.stream, msgSeq: segment.msgSeq), now: now) }
                    inbound += deliver.map { .message(stream: segment.stream, payload: $0) }
                }
            case .datagram(let stream, let payload):
                if checkData(stream, .unreliable) != nil { inbound.append(.datagram(stream: stream, payload: payload)) }
            case .mediaFragment(let fragment):
                if checkData(fragment.stream, .media) != nil { inbound.append(.fragment(fragment)) }
            case .nack(let nack):
                if checkFeedback(nack.stream) { inbound.append(.nack(nack)) }
            case .refreshRequest(let request):
                if checkFeedback(request.stream) { inbound.append(.refresh(request)) }
            }
        }
        return inbound
    }

    /// A data chunk must name a listed stream of its class, travelling towards this end.
    private func checkData(_ stream: UInt8, _ expected: StreamEntry.Class) -> StreamEntry? {
        guard let entry = streams.entry(stream), entry.streamClass == expected, receives(entry) else {
            stats.streamViolations += 1
            return nil
        }
        return entry
    }

    /// A feedback chunk travels against its stream's data: towards the end that sends it.
    private func checkFeedback(_ stream: UInt8) -> Bool {
        guard let entry = streams.entry(stream), sends(entry) else {
            stats.streamViolations += 1
            return false
        }
        return true
    }

    private func acknowledge(_ ack: ReliableAck, now: UInt64) {
        if !pendingAcks.contains(ack) { pendingAcks.append(ack) }
        if ackDue == nil { ackDue = now + Self.ackDelay }
    }

    private func handle(_ feedback: Feedback, reporterSendTime: UInt32, now: UInt64) {
        for ack in feedback.acks { senders[ack.stream]?.acknowledge(ack.msgSeq) }
        let reported = feedback.arrivals
        stats.reportedReceived += reported.count
        stats.reportedLost += feedback.received.count - reported.count
        guard let newest = reported.last else { return }
        let pn = Packet.reconstruct(expected: nextPacketNumber, transportSeq: newest.seq)
        if let v = validation, pn >= v.firstPacket { validation = nil }
        let entry = sentLog[Int(pn % UInt64(Self.sentLogSize))]
        guard entry.pn == pn else { return }
        let hold = wrappingDifference(reporterSendTime, newest.time)
        let elapsed = Int64(now - entry.time) - max(hold, 0)
        if elapsed > 0 { rtt.add(UInt64(elapsed)) }
    }

    // MARK: Sending

    /// Queues a reliable message; false if the stream is unknown, not ours to send on, or full.
    @discardableResult
    public func send(message: Bytes, on stream: UInt8) -> Bool {
        let maxSegment = maxDatagramSize - Packet.overhead - 3 - ReliableSegment.headerLength
        return senders[stream]?.enqueue(message, maxSegmentPayload: maxSegment) ?? false
    }

    /// Queues a small chunk (NACK, REFRESH_REQUEST, CLOSE) for the next control datagram.
    public func queue(_ chunk: Chunk) { control.append(chunk.encoded) }

    /// Seals one datagram. Nil if an unvalidated address has used its allowance.
    public func seal(_ chunks: Bytes, now: UInt64) -> Bytes? {
        let size = chunks.count + Packet.overhead
        if var v = validation {
            guard v.sent + size <= 3 * v.received else {
                stats.blockedByValidation += 1
                return nil
            }
            v.sent += size
            validation = v
        }
        let pn = nextPacketNumber
        nextPacketNumber += 1
        let header = ProtectedHeader(
            sessionID: sessionID, transportSeq: UInt32(truncatingIfNeeded: pn),
            sendTimeMicros: UInt32(truncatingIfNeeded: now))
        sentLog[Int(pn % UInt64(Self.sentLogSize))] = (pn, now)
        lastSent = now
        stats.packetsSent += 1
        stats.bytesSent += size
        return Packet.seal(header: header, packetNumber: pn, key: sendKey, chunks: chunks)
    }

    /// Sends a PING with the next flush: at the start of a session, so that the host hears from
    /// the client at once and takes its first round-trip sample.
    public func requestPing() { pingWanted = true }

    /// Latency budget for a frame: `max(50 ms, 2 × srtt + 20 ms)`, at most 150 ms.
    public var latencyBudget: UInt64 { min(max(50_000, 2 * rtt.smoothed + 20_000), 150_000) }

    var retransmitTimeout: UInt64 { max(rtt.smoothed * 3 / 2, 20_000) }

    /// Everything but media that is due: pongs, feedback, reliable segments, queued control
    /// chunks and keepalive, packed into as few datagrams as fit.
    public func flush(now: UInt64) -> [Bytes] {
        var chunks: [Bytes] = []
        for pong in pongs {
            chunks.append(Chunk.pong(id: pong.id, holdMicros: UInt32(clamping: now - pong.arrival)).encoded)
        }
        pongs.removeAll()
        if let due = feedbackDue, now >= due {
            chunks += buildFeedback()
            lastFeedback = now
        }
        for sender in senders.values {
            for segment in sender.due(now: now, timeout: retransmitTimeout) { chunks.append(Chunk.reliable(segment).encoded) }
        }
        chunks += control
        control.removeAll()
        if pingWanted || (chunks.isEmpty && now >= lastSent + Self.keepaliveInterval) {
            pingWanted = false
            pings[nextPingID] = now
            if pings.count > 16, let oldest = pings.min(by: { $0.value < $1.value }) { pings[oldest.key] = nil }
            chunks.append(Chunk.ping(id: nextPingID).encoded)
            nextPingID &+= 1
        }
        return pack(chunks, now: now)
    }

    /// Chunks into datagrams no larger than `maxDatagramSize`.
    private func pack(_ chunks: [Bytes], now: UInt64) -> [Bytes] {
        let limit = maxDatagramSize - Packet.overhead
        var out: [Bytes] = []
        var current = Bytes()
        for chunk in chunks {
            if !current.isEmpty, current.count + chunk.count > limit {
                if let datagram = seal(current, now: now) { out.append(datagram) }
                current.removeAll(keepingCapacity: true)
            }
            current += chunk
        }
        if !current.isEmpty, let datagram = seal(current, now: now) { out.append(datagram) }
        return out
    }

    /// FEEDBACK chunks covering every unreported arrival, and the pending acknowledgements.
    private func buildFeedback() -> [Bytes] {
        arrivals.sort { $0.pn < $1.pn }
        var chunks: [Bytes] = []
        var acks = pendingAcks
        pendingAcks.removeAll()
        ackDue = nil
        var remaining = arrivals[...]
        let room = maxDatagramSize - Packet.overhead
        repeat {
            let ackCount = min(acks.count, 32)
            // 13 bytes of fixed fields and ack count, 5 per ack, then 17 bits per packet covered.
            let budget = room - 15 - 5 * ackCount
            let maxCount = budget * 8 / 17
            var covered: [(offset: Int, time: UInt32)] = []
            var base: UInt64 = 0
            var count = 0
            if let first = remaining.first {
                base = first.pn
                while let next = remaining.first, next.pn - base < UInt64(maxCount) {
                    covered.append((Int(next.pn - base), UInt32(truncatingIfNeeded: next.time)))
                    count = Int(next.pn - base) + 1
                    remaining = remaining.dropFirst()
                }
            }
            let feedback = Feedback(
                baseSeq: UInt32(truncatingIfNeeded: base), count: count, arrivals: covered,
                acks: Array(acks.prefix(ackCount)))
            acks.removeFirst(ackCount)
            chunks.append(Chunk.feedback(feedback).encoded)
            if count > 0 { reportedBelow = base + UInt64(count) }
        } while !remaining.isEmpty || !acks.isEmpty
        arrivals.removeAll()
        elicited = false
        return chunks
    }

    private var feedbackDue: UInt64? {
        var due: UInt64?
        if !arrivals.isEmpty {
            due = lastFeedback + (elicited ? Self.feedbackInterval : Self.idleFeedbackInterval)
        }
        if let ackDue { due = min(due ?? .max, ackDue) }
        return due
    }

    /// When `flush` next has something to do.
    public func nextDeadline() -> UInt64 {
        var deadline = lastSent + Self.keepaliveInterval
        if let feedbackDue { deadline = min(deadline, feedbackDue) }
        for sender in senders.values {
            if let d = sender.nextDeadline(timeout: retransmitTimeout) { deadline = min(deadline, d) }
        }
        if !control.isEmpty || !pongs.isEmpty || pingWanted { deadline = 0 }
        return deadline
    }
}
