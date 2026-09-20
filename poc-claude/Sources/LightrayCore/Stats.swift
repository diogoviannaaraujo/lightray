/// A log2-bucketed histogram. Fixed storage, so every update is allocation-free.
public struct Log2Histogram: Sendable {
    public var buckets: InlineArray<32, UInt32>
    public var count: UInt64
    public var sum: UInt64
    public var maxValue: UInt64

    public init() {
        buckets = InlineArray<32, UInt32>(repeating: 0)
        count = 0; sum = 0; maxValue = 0
    }

    @inlinable
    public mutating func record(_ v: UInt64) {
        let b = v == 0 ? 0 : min(31, 64 - v.leadingZeroBitCount)
        buckets[b] &+= 1
        count &+= 1
        sum &+= v
        if v > maxValue { maxValue = v }
    }

    public var mean: Double { count == 0 ? 0 : Double(sum) / Double(count) }

    /// Upper bound of the bucket holding the `q` quantile — resolution is a
    /// factor of two, which is all a stats overlay needs.
    public func quantile(_ q: Double) -> UInt64 {
        guard count > 0 else { return 0 }
        let target = UInt64(Double(count) * q)
        var seen: UInt64 = 0
        for i in 0..<32 {
            seen &+= UInt64(buckets[i])
            if seen >= target { return i == 0 ? 0 : 1 << UInt64(i - 1) }
        }
        return maxValue
    }

    public mutating func clear() {
        for i in 0..<32 { buckets[i] = 0 }
        count = 0; sum = 0; maxValue = 0
    }
}

/// Exponentially weighted moving average over nanosecond quantities.
public struct EWMA: Sendable {
    public var value: Double = 0
    public var initialized = false
    public let alpha: Double

    public init(alpha: Double) { self.alpha = alpha }

    @inlinable
    public mutating func update(_ sample: Double) {
        if initialized { value += alpha * (sample - value) }
        else { value = sample; initialized = true }
    }

    public mutating func clear() { value = 0; initialized = false }
}

/// srtt/rttvar per RFC 6298, plus the RTO the reliable channel uses.
public struct RTTEstimator: Sendable {
    public private(set) var latest: Interval = .zero
    public private(set) var smoothed: Interval = .zero
    public private(set) var variance: Interval = .zero
    public private(set) var minimum: Interval = Interval(nanos: .max)
    public private(set) var samples: UInt64 = 0

    public init() {}

    public mutating func record(_ sample: Interval) {
        guard sample.nanos > 0 else { return }
        latest = sample
        samples &+= 1
        if sample < minimum { minimum = sample }
        if samples == 1 {
            smoothed = sample
            variance = sample / 2
            return
        }
        let delta = smoothed.nanos > sample.nanos ? smoothed.nanos - sample.nanos : sample.nanos - smoothed.nanos
        variance = Interval(nanos: (variance.nanos * 3 + delta) / 4)
        smoothed = Interval(nanos: (smoothed.nanos * 7 + sample.nanos) / 8)
    }

    /// srtt + 4·rttvar, floored at 20 ms and capped at 1 s.
    public var rto: Interval {
        let raw = smoothed.nanos + 4 * variance.nanos
        return Interval(nanos: min(max(raw, 20_000_000), 1_000_000_000))
    }

    public var hasSample: Bool { samples > 0 }
}

/// Per-path receive/send counters. Updated inline on every packet.
public struct PathStats: Sendable {
    public var packetsSent: UInt64 = 0
    public var packetsReceived: UInt64 = 0
    public var bytesSent: UInt64 = 0
    public var bytesReceived: UInt64 = 0
    public var datagramsDropped: UInt64 = 0      // failed auth, bad version, malformed
    public var replayDropped: UInt64 = 0
    public var reordered: UInt64 = 0
    public var duplicates: UInt64 = 0
    public var gaps: UInt64 = 0                   // sequence numbers never seen
    public var retransmitsSent: UInt64 = 0
    public var nacksSent: UInt64 = 0
    public var nacksReceived: UInt64 = 0
    public var rebinds: UInt64 = 0

    public var rtt = RTTEstimator()
    /// RFC 3550 interarrival jitter, in nanoseconds.
    public var jitterNanos: Double = 0
    /// Relative one-way delay minus its running minimum: the queuing estimate.
    public var queuingDelay: Interval = .zero
    public var owdBaselineMicros: Int64 = .max
    /// Loss the peer reported over the most recent feedback window.
    public var reportedLoss: Double = 0

    public init() {}

    /// Jitter from a send/arrival pair, both in microseconds on their own clocks;
    /// only the difference of differences is used, so the clocks need no relation.
    @inlinable
    public mutating func recordTransit(sendMicros: UInt32, arrivalMicros: UInt32, previous: inout Int64?) {
        let transit = Int64(Int32(bitPattern: arrivalMicros &- sendMicros))
        if let prev = previous {
            let d = abs(transit - prev)
            jitterNanos += (Double(d * 1000) - jitterNanos) / 16
        }
        previous = transit
        if transit < owdBaselineMicros { owdBaselineMicros = transit }
        let q = transit - owdBaselineMicros
        queuingDelay = Interval(nanos: q > 0 ? UInt64(q) * 1000 : 0)
    }
}

/// Per-stream media counters.
public struct StreamStats: Sendable {
    public var framesSubmitted: UInt64 = 0
    public var framesCompleted: UInt64 = 0
    public var framesDelivered: UInt64 = 0
    public var framesIncomplete: UInt64 = 0        // gave up at the deadline
    public var framesGatedUndecodable: UInt64 = 0  // held back by DecodabilityTracker
    public var fragmentsSent: UInt64 = 0
    public var fragmentsReceived: UInt64 = 0
    public var fragmentsDuplicate: UInt64 = 0
    public var bytesDelivered: UInt64 = 0
    public var keyframesDelivered: UInt64 = 0
    public var refreshRequestsSent: UInt64 = 0
    public var refreshRequestsReceived: UInt64 = 0
    public var ltrAcksSent: UInt64 = 0
    /// Submit-to-complete latency, in microseconds.
    public var completionLatency = Log2Histogram()
    public var pacerQueueDepth: Int = 0
    public var pacerQueueBytes: Int = 0

    public init() {}
}

public struct ReconnectStats: Sendable {
    public var parks: UInt64 = 0
    public var resumes: UInt64 = 0
    public var sessionsExpired: UInt64 = 0
    public var sessionUnknownSent: UInt64 = 0
    public var sessionUnknownReceived: UInt64 = 0
    public var handshakes: UInt64 = 0
    public var handshakesAdopted: UInt64 = 0
    /// Resume request to first delivered frame, in microseconds.
    public var resumeLatency = Log2Histogram()

    public init() {}
}

/// A coarse summary for a UI indicator.
public struct LinkQuality: Sendable {
    public enum Grade: String, Sendable { case good, fair, poor, stalled }
    public var grade: Grade
    public var loss: Double
    public var rtt: Interval
    public var queuingDelay: Interval
    public var backstopEngaged: Bool

    public init(loss: Double, rtt: Interval, queuingDelay: Interval, backstopEngaged: Bool, connected: Bool) {
        self.loss = loss
        self.rtt = rtt
        self.queuingDelay = queuingDelay
        self.backstopEngaged = backstopEngaged
        if !connected { grade = .stalled }
        else if loss > 0.05 || queuingDelay > .milliseconds(100) { grade = .poor }
        else if loss > 0.01 || queuingDelay > .milliseconds(30) || backstopEngaged { grade = .fair }
        else { grade = .good }
    }
}

/// Everything the runtime publishes to an overlay at <= 10 Hz.
public struct StatsSnapshot: Sendable {
    public var path = PathStats()
    public var streams: [UInt8: StreamStats] = [:]
    public var reconnect = ReconnectStats()
    public var targetBitrate: UInt32 = 0
    public var backstopEngaged = false
    public var sessionID: UInt32 = 0
    public var state: String = "idle"
    public var timeline: [TimelineEvent] = []

    public init() {}

    public var linkQuality: LinkQuality {
        LinkQuality(loss: path.reportedLoss, rtt: path.rtt.smoothed, queuingDelay: path.queuingDelay,
                    backstopEngaged: backstopEngaged, connected: state == "established" || state == "resumed")
    }
}
