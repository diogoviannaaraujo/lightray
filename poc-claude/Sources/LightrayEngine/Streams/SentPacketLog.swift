import LightrayCore

/// What one sent datagram carried, indexed by `transport_seq`.
///
/// This is where a future congestion controller plugs in: it already records
/// send time and byte count for every packet, acked or not.
struct SentPacket {
    enum Payload {
        case none
        case media(stream: UInt8, frameID: UInt32, fragmentIndex: UInt16)
        case reliable(stream: UInt8, msgSeq: UInt32, segIndex: UInt16)
        case control
    }
    var seq: UInt32 = 0
    var sentAt: Instant = .zero
    var bytes: UInt16 = 0
    var payload: Payload = .none
    var acked = false
    var declaredLost = false
    var inUse = false
}

/// A ring of the most recent sent packets, indexed by `transport_seq` modulo its
/// capacity. Sized so it always outlives the feedback that reports on it.
struct SentPacketLog {
    private var entries: [SentPacket]
    private let mask: Int
    private(set) var highestSeq: UInt32 = 0
    private(set) var count: UInt64 = 0

    init(capacity: Int = 8192) {
        var c = 1
        while c < capacity { c <<= 1 }
        entries = [SentPacket](repeating: SentPacket(), count: c)
        mask = c - 1
    }

    mutating func record(seq: UInt32, at: Instant, bytes: Int, payload: SentPacket.Payload) {
        var e = SentPacket()
        e.seq = seq
        e.sentAt = at
        e.bytes = UInt16(min(bytes, Int(UInt16.max)))
        e.payload = payload
        e.inUse = true
        entries[Int(seq) & mask] = e
        if count == 0 || serialGreater(seq, highestSeq) { highestSeq = seq }
        count &+= 1
    }

    /// The record for `seq`, or nil once the ring has wrapped past it.
    func lookup(_ seq: UInt32) -> SentPacket? {
        let e = entries[Int(seq) & mask]
        return e.inUse && e.seq == seq ? e : nil
    }

    mutating func markAcked(_ seq: UInt32) -> SentPacket? {
        let i = Int(seq) & mask
        guard entries[i].inUse, entries[i].seq == seq, !entries[i].acked else { return nil }
        entries[i].acked = true
        return entries[i]
    }

    mutating func markLost(_ seq: UInt32) -> SentPacket? {
        let i = Int(seq) & mask
        guard entries[i].inUse, entries[i].seq == seq, !entries[i].acked, !entries[i].declaredLost
        else { return nil }
        entries[i].declaredLost = true
        return entries[i]
    }

    mutating func reset() {
        for i in 0..<entries.count { entries[i].inUse = false }
        highestSeq = 0
        count = 0
    }
}
