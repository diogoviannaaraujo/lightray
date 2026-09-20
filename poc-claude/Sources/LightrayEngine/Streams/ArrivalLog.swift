import LightrayCore

/// Arrival times of received packets, by `transport_seq`, so FEEDBACK can report
/// both what arrived and when.
struct ArrivalLog {
    private var seqs: [UInt32]
    private var micros: [UInt32]
    private var present: [Bool]
    private let mask: Int

    private(set) var highest: UInt32 = 0
    private(set) var seen = false
    /// Oldest sequence number not yet reported in a FEEDBACK.
    private(set) var nextToReport: UInt32 = 0

    init(capacity: Int = 4096) {
        var c = 1
        while c < capacity { c <<= 1 }
        seqs = [UInt32](repeating: 0, count: c)
        micros = [UInt32](repeating: 0, count: c)
        present = [Bool](repeating: false, count: c)
        mask = c - 1
    }

    var capacity: Int { mask + 1 }

    mutating func record(seq: UInt32, micros m: UInt32) {
        let i = Int(seq) & mask
        seqs[i] = seq
        micros[i] = m
        present[i] = true
        if !seen {
            seen = true
            highest = seq
            nextToReport = seq
        } else if serialGreater(seq, highest) {
            highest = seq
        }
    }

    func arrivalMicros(_ seq: UInt32) -> UInt32? {
        let i = Int(seq) & mask
        return present[i] && seqs[i] == seq ? micros[i] : nil
    }

    /// Whether there is anything new to report.
    var hasUnreported: Bool { seen && serialGreaterOrEqual(highest, nextToReport) }

    /// How many sequence numbers a report would cover, capped by the ring so a
    /// long stall cannot make the engine report slots it has already overwritten.
    func unreportedCount(limit: Int) -> Int {
        guard hasUnreported else { return 0 }
        let span = Int(highest &- nextToReport) + 1
        return min(span, min(limit, capacity))
    }

    /// Marks `count` sequence numbers from `nextToReport` as reported.
    mutating func advance(by count: Int) {
        nextToReport = nextToReport &+ UInt32(count)
    }

    /// Skips ahead when the range to report is older than the ring holds.
    mutating func catchUp() {
        if seen, Int(highest &- nextToReport) >= capacity {
            nextToReport = highest &- UInt32(capacity - 1)
        }
    }

    mutating func reset() {
        for i in 0...mask { present[i] = false }
        seen = false
        highest = 0
        nextToReport = 0
    }
}
