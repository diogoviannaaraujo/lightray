/// A point on a suspending monotonic timeline, in nanoseconds.
///
/// "Suspending" means it does not advance across system sleep, which is what
/// `CLOCK_UPTIME_RAW` gives us. The protocol never carries an `Instant` on the
/// wire; only microsecond deltas travel between peers.
public struct Instant: Comparable, Hashable, Sendable {
    public var nanos: UInt64

    @inlinable public init(nanos: UInt64) { self.nanos = nanos }

    public static let zero = Instant(nanos: 0)

    @inlinable public static func < (a: Self, b: Self) -> Bool { a.nanos < b.nanos }

    /// Saturating, so a clock that appears to go backwards yields zero rather than wrapping.
    @inlinable public static func - (a: Self, b: Self) -> Interval {
        Interval(nanos: a.nanos > b.nanos ? a.nanos - b.nanos : 0)
    }

    @inlinable public static func + (a: Self, d: Interval) -> Self { Instant(nanos: a.nanos &+ d.nanos) }
    @inlinable public static func += (a: inout Self, d: Interval) { a = a + d }

    /// Low 32 bits of the microsecond clock, as carried in `send_time_us`. Wraps every 71.6 min.
    @inlinable public var microsTruncated: UInt32 { UInt32(truncatingIfNeeded: nanos / 1000) }
}

/// A non-negative duration in nanoseconds.
public struct Interval: Comparable, Hashable, Sendable {
    public var nanos: UInt64

    @inlinable public init(nanos: UInt64) { self.nanos = nanos }

    public static let zero = Interval(nanos: 0)

    @inlinable public static func nanoseconds(_ n: UInt64) -> Self { Self(nanos: n) }
    @inlinable public static func microseconds(_ n: UInt64) -> Self { Self(nanos: n &* 1_000) }
    @inlinable public static func milliseconds(_ n: UInt64) -> Self { Self(nanos: n &* 1_000_000) }
    @inlinable public static func seconds(_ n: UInt64) -> Self { Self(nanos: n &* 1_000_000_000) }

    @inlinable public var micros: UInt64 { nanos / 1_000 }
    @inlinable public var millis: UInt64 { nanos / 1_000_000 }
    @inlinable public var seconds: Double { Double(nanos) / 1e9 }

    @inlinable public static func < (a: Self, b: Self) -> Bool { a.nanos < b.nanos }
    @inlinable public static func + (a: Self, b: Self) -> Self { Self(nanos: a.nanos &+ b.nanos) }
    @inlinable public static func - (a: Self, b: Self) -> Self {
        Self(nanos: a.nanos > b.nanos ? a.nanos - b.nanos : 0)
    }
    @inlinable public static func * (a: Self, k: Double) -> Self { Self(nanos: UInt64(Double(a.nanos) * k)) }
    @inlinable public static func / (a: Self, k: UInt64) -> Self { Self(nanos: k == 0 ? 0 : a.nanos / k) }
}

/// A source of `Instant`s. The sans-IO engines never call one directly: the
/// runtime reads the clock and passes `at:` into every entry point, so tests can
/// drive the same code from a `ManualClock`.
public protocol MonotonicClock: AnyObject, Sendable {
    func now() -> Instant
}
