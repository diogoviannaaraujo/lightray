/// A growable bitset over 64-bit words, used for fragment arrival maps and the
/// replay window. Words are allocated when a slot is created, never per packet.
public struct Bitset: Sendable {
    public var words: [UInt64]
    public var count: Int

    public init() { words = []; count = 0 }

    public init(capacity: Int) {
        count = capacity
        words = [UInt64](repeating: 0, count: (capacity + 63) / 64)
    }

    /// Resizes to hold `capacity` bits, clearing everything. Reuses the existing
    /// allocation when it is already large enough.
    public mutating func reset(capacity: Int) {
        let needed = (capacity + 63) / 64
        if words.count < needed {
            words = [UInt64](repeating: 0, count: needed)
        } else {
            for i in 0..<words.count { words[i] = 0 }
        }
        count = capacity
    }

    @inlinable
    public subscript(i: Int) -> Bool {
        get {
            guard i >= 0, i < count else { return false }
            return words[i >> 6] & (1 << UInt64(i & 63)) != 0
        }
        set {
            guard i >= 0, i < count else { return }
            if newValue { words[i >> 6] |= 1 << UInt64(i & 63) }
            else { words[i >> 6] &= ~(1 << UInt64(i & 63)) }
        }
    }

    /// Sets bit `i` and reports whether it was previously clear (a first arrival).
    @inlinable
    public mutating func testAndSet(_ i: Int) -> Bool {
        guard i >= 0, i < count else { return false }
        let mask: UInt64 = 1 << UInt64(i & 63)
        let w = i >> 6
        let wasClear = words[w] & mask == 0
        words[w] |= mask
        return wasClear
    }

    @inlinable
    public var popcount: Int {
        var n = 0
        for w in words { n += w.nonzeroBitCount }
        return n
    }

    public var isComplete: Bool { popcount == count }

    /// Index of the first clear bit at or after `from`, or nil when none is left.
    public func firstClear(from: Int = 0) -> Int? {
        var i = from
        while i < count {
            let w = i >> 6
            let bitsUsed = i & 63
            let masked = ~words[w] & (UInt64.max << UInt64(bitsUsed))
            if masked != 0 {
                let idx = (w << 6) + masked.trailingZeroBitCount
                return idx < count ? idx : nil
            }
            i = (w + 1) << 6
        }
        return nil
    }

    /// Calls `body` with each maximal run of clear bits, as (first, count).
    /// This is how the NACK scheduler turns an arrival map into NACK entries.
    public func forEachClearRun(_ body: (Int, Int) -> Void) {
        var i = 0
        while let first = firstClear(from: i) {
            var last = first
            while last + 1 < count, !self[last + 1] { last += 1 }
            body(first, last - first + 1)
            i = last + 1
        }
    }
}
