import Darwin

/// The real clock: `CLOCK_UPTIME_RAW`, which stops across system sleep.
///
/// A lid close ends a Lightray session rather than parking across it, so the
/// engine never needs a timeline that counts through sleep.
public final class SystemClock: MonotonicClock {
    public static let shared = SystemClock()
    public init() {}
    @inlinable public func now() -> Instant { Instant(nanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) }
}

/// Thread CPU time, used by the runtime to report per-packet CPU cost.
@inlinable public func threadCPUNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
