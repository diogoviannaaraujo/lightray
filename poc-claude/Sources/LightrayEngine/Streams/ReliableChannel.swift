import LightrayCore

/// Ordered, acknowledged messages on a reliable stream. Stream 0 is the control
/// channel, which carries RECONFIGURE, RECONFIGURE_RESULT and STATE.
///
/// Acknowledgement rides on FEEDBACK rather than a second ack scheme: the packet
/// that carried a segment is reported received, so the segment is acked. An
/// unacked segment is resent on RTO.
struct ReliableChannel {
    struct Segment {
        var msgSeq: UInt32
        var index: UInt16
        var count: UInt16
        var bytes: [UInt8]
        var sentAt: Instant = .zero
        var attempts = 0
        var acked = false
        var inFlight = false
    }

    let stream: UInt8
    private var nextMsgSeq: UInt32 = 0
    private var outbound: [Segment] = []

    /// Receive side: segments per message, plus in-order delivery bookkeeping.
    private var inbound: [UInt32: [Int: [UInt8]]] = [:]
    private var inboundCounts: [UInt32: UInt16] = [:]
    /// The next message to deliver. A channel's `msg_seq` starts at 0, so this
    /// never has to be guessed from whichever segment happens to arrive first —
    /// guessing would skip a lost leading message permanently.
    private var nextExpected: UInt32 = 0

    init(stream: UInt8) { self.stream = stream }

    // MARK: Send

    /// Queues a message, split to fit `maxSegmentBytes`.
    mutating func send(_ bytes: [UInt8], maxSegmentBytes: Int) {
        let seq = nextMsgSeq
        nextMsgSeq &+= 1
        let size = max(1, maxSegmentBytes)
        let count = max(1, (bytes.count + size - 1) / size)
        for i in 0..<count {
            let lo = i * size
            let hi = min(lo + size, bytes.count)
            outbound.append(Segment(msgSeq: seq, index: UInt16(i), count: UInt16(count),
                                    bytes: Array(bytes[lo..<hi])))
        }
    }

    /// The next segment to put on the wire, or nil when nothing is due.
    mutating func nextSendable(at now: Instant, rto: Interval) -> Segment? {
        for i in 0..<outbound.count where !outbound[i].acked {
            if !outbound[i].inFlight { return outbound[i] }
            if now - outbound[i].sentAt >= rto { return outbound[i] }
        }
        return nil
    }

    mutating func markSent(msgSeq: UInt32, index: UInt16, at now: Instant) {
        guard let i = outbound.firstIndex(where: { $0.msgSeq == msgSeq && $0.index == index }) else { return }
        outbound[i].inFlight = true
        outbound[i].sentAt = now
        outbound[i].attempts += 1
    }

    mutating func markAcked(msgSeq: UInt32, index: UInt16) {
        guard let i = outbound.firstIndex(where: { $0.msgSeq == msgSeq && $0.index == index }) else { return }
        outbound[i].acked = true
        // Drop the whole message once every segment is acked.
        if !outbound.contains(where: { $0.msgSeq == msgSeq && !$0.acked }) {
            outbound.removeAll { $0.msgSeq == msgSeq }
        }
    }

    /// Earliest RTO among in-flight segments.
    func nextRetransmitDeadline(rto: Interval) -> Instant? {
        var earliest: Instant?
        for s in outbound where s.inFlight && !s.acked {
            let t = s.sentAt + rto
            if earliest == nil || t < earliest! { earliest = t }
        }
        return earliest
    }

    var hasPendingOutbound: Bool { outbound.contains { !$0.acked } }
    var pendingCount: Int { outbound.count { !$0.acked } }

    // MARK: Receive

    /// Adds a segment and returns every message that is now deliverable, in order.
    mutating func receive(_ header: ReliableHeader, payload: RawSpan) -> [[UInt8]] {
        // Already delivered: a duplicate from a retransmission.
        if serialGreater(nextExpected, header.msgSeq) { return [] }

        var bytes = [UInt8](repeating: 0, count: payload.byteCount)
        if payload.byteCount > 0 {
            bytes.withUnsafeMutableBytes { dst in payload.withUnsafeBytes { dst.copyMemory(from: $0) } }
        }
        inbound[header.msgSeq, default: [:]][Int(header.segIndex)] = bytes
        inboundCounts[header.msgSeq] = header.segCount

        var delivered: [[UInt8]] = []
        while let count = inboundCounts[nextExpected],
              let parts = inbound[nextExpected],
              parts.count == Int(count) {
            var message: [UInt8] = []
            for i in 0..<Int(count) { message.append(contentsOf: parts[i] ?? []) }
            delivered.append(message)
            inbound[nextExpected] = nil
            inboundCounts[nextExpected] = nil
            nextExpected &+= 1
        }
        return delivered
    }

    /// A resume flushes both directions and restarts the numbering at 0. The
    /// control channel re-sends STATE afterwards, so nothing in flight matters.
    ///
    /// Restarting the numbering is safe because a datagram sent before the resume
    /// cannot reach this channel afterwards: on a plain resume the replay window
    /// survives and already holds that packet number, and on a re-handshake the
    /// keys are new, so the packet cannot even be opened.
    mutating func reset() {
        outbound.removeAll(keepingCapacity: true)
        inbound.removeAll(keepingCapacity: true)
        inboundCounts.removeAll(keepingCapacity: true)
        nextExpected = 0
        nextMsgSeq = 0
    }
}
