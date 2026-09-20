import LightrayCore

/// A clock the test moves by hand, so every scenario runs in virtual time and
/// gives the same answer every run.
public final class ManualClock: MonotonicClock, @unchecked Sendable {
    public private(set) var current: Instant

    public init(_ start: Instant = Instant(nanos: 1_000_000_000)) { current = start }

    public func now() -> Instant { current }

    public func advance(_ by: Interval) { current = current + by }

    public func set(_ to: Instant) {
        precondition(to.nanos >= current.nanos, "a monotonic clock does not go backwards")
        current = to
    }
}

/// SplitMix64: a small, seeded generator so a loss pattern is reproducible.
public struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }

    public mutating func chance(_ p: Double) -> Bool { p > 0 && unit() < p }
}
