/// The sending half of a `RELIABLE` stream, `docs/input.md#reliable-0x02`: messages split into
/// segments, kept until acknowledged, retransmitted on a doubling timeout.
final class ReliableSender {
    let stream: UInt8
    private(set) var nextSeq: UInt32 = 0
    private var messages: [Message] = []
    static let maxUnacknowledged = 1024

    private struct Message {
        let seq: UInt32
        let segments: [Bytes]
        var sentAt: UInt64?
        var attempts = 0
    }

    init(stream: UInt8) { self.stream = stream }

    var isIdle: Bool { messages.isEmpty }
    var unacknowledged: Int { messages.count }

    /// Queues a message; false if too many are unacknowledged.
    func enqueue(_ payload: Bytes, maxSegmentPayload: Int) -> Bool {
        guard messages.count < Self.maxUnacknowledged else { return false }
        var segments: [Bytes] = []
        var offset = 0
        repeat {
            let end = min(offset + maxSegmentPayload, payload.count)
            segments.append(Array(payload[offset..<end]))
            offset = end
        } while offset < payload.count
        messages.append(Message(seq: nextSeq, segments: segments))
        nextSeq &+= 1
        return true
    }

    func acknowledge(_ seq: UInt32) {
        if let i = messages.firstIndex(where: { $0.seq == seq }) { messages.remove(at: i) }
    }

    /// Segments to send now: every message never sent, and every one whose timeout has passed.
    func due(now: UInt64, timeout: UInt64) -> [ReliableSegment] {
        var out: [ReliableSegment] = []
        for i in messages.indices {
            let m = messages[i]
            if let sentAt = m.sentAt, now < sentAt + (timeout << UInt64(min(m.attempts - 1, 6))) { continue }
            for (index, payload) in m.segments.enumerated() {
                out.append(ReliableSegment(
                    stream: stream, msgSeq: m.seq, segIndex: UInt16(index), segCount: UInt16(m.segments.count),
                    payload: payload))
            }
            messages[i].sentAt = now
            messages[i].attempts += 1
        }
        return out
    }

    func nextDeadline(timeout: UInt64) -> UInt64? {
        messages.compactMap { m in m.sentAt.map { $0 + (timeout << UInt64(min(m.attempts - 1, 6))) } }.min()
    }
}

/// The receiving half: reassembles, acknowledges complete messages, delivers them in order with
/// no gaps, and bounds everything it holds.
final class ReliableReceiver {
    let stream: UInt8
    private(set) var expected: UInt32 = 0
    private var partial: [UInt32: Partial] = [:]
    private var complete: [UInt32: Bytes] = [:]

    static let maxAhead: UInt32 = 1024
    static let maxMessageBytes = 1 << 20

    private struct Partial {
        let segCount: UInt16
        var segments: [Bytes?]
        var received = 0
        var bytes = 0
    }

    enum Outcome: Equatable {
        /// Acknowledge the message, and deliver these messages in order.
        case accepted(ack: Bool, deliver: [Bytes])
        case discarded
    }

    init(stream: UInt8) { self.stream = stream }

    func receive(_ s: ReliableSegment) -> Outcome {
        // Behind the expected number: already delivered. Acknowledge again, deliver nothing.
        if serialNewer(expected, than: s.msgSeq) { return .accepted(ack: true, deliver: []) }
        guard s.msgSeq &- expected < Self.maxAhead else { return .discarded }
        if complete[s.msgSeq] != nil { return .accepted(ack: true, deliver: []) }
        var p = partial[s.msgSeq] ?? Partial(segCount: s.segCount, segments: Array(repeating: nil, count: Int(s.segCount)))
        guard p.segCount == s.segCount else { return .discarded }
        if p.segments[Int(s.segIndex)] != nil { return .accepted(ack: false, deliver: []) }
        guard p.bytes + s.payload.count <= Self.maxMessageBytes else { return .discarded }
        p.segments[Int(s.segIndex)] = s.payload
        p.received += 1
        p.bytes += s.payload.count
        guard p.received == Int(p.segCount) else {
            partial[s.msgSeq] = p
            return .accepted(ack: false, deliver: [])
        }
        partial[s.msgSeq] = nil
        complete[s.msgSeq] = p.segments.flatMap { $0! }
        var deliver: [Bytes] = []
        while let message = complete.removeValue(forKey: expected) {
            deliver.append(message)
            expected &+= 1
        }
        return .accepted(ack: true, deliver: deliver)
    }
}
