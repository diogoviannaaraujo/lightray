import LightrayCore

/// A token bucket that spreads a frame's bytes across its frame interval.
///
/// Without it a 500 KB IDR is dumped into the socket at line rate and fills the
/// bottleneck queue; with it the burst is bounded by `linkRateCeiling`.
struct Pacer {
    /// Bytes per second.
    private(set) var rate: Double
    private(set) var tokens: Double
    private var lastRefill: Instant
    var maxBurstBytes: Int

    init(rate: Double, maxBurstBytes: Int, at: Instant) {
        self.rate = max(rate, 1)
        self.tokens = Double(maxBurstBytes)
        self.lastRefill = at
        self.maxBurstBytes = maxBurstBytes
    }

    /// `max(pacingGain × targetBitrate, frameBytes / spreadTarget)`, capped by
    /// the link-rate ceiling.
    static func rate(targetBitrate: UInt32, frameBytes: Int, frameInterval: Interval,
                     config: EngineConfig) -> Double {
        let fromBitrate = Double(targetBitrate) * config.pacingGain / 8
        let spreadSeconds = max(frameInterval.seconds * config.spreadTarget, 0.001)
        let fromFrame = Double(frameBytes) / spreadSeconds
        let ceiling = Double(config.linkRateCeiling) / 8
        return min(max(fromBitrate, fromFrame), ceiling)
    }

    mutating func setRate(_ r: Double) { rate = max(r, 1) }

    mutating func refill(at now: Instant) {
        let elapsed = (now - lastRefill).seconds
        guard elapsed > 0 else { return }
        tokens = min(tokens + elapsed * rate, Double(maxBurstBytes))
        lastRefill = now
    }

    mutating func take(_ bytes: Int) -> Bool {
        guard tokens >= Double(bytes) else { return false }
        tokens -= Double(bytes)
        return true
    }

    /// Control traffic is never delayed, so it spends tokens it may not have.
    mutating func takeUnconditionally(_ bytes: Int) {
        tokens -= Double(bytes)
    }

    /// When `bytes` will be affordable, so the engine can arm a timer instead of
    /// spinning.
    func nextAvailable(bytes: Int, from now: Instant) -> Instant? {
        guard tokens < Double(bytes) else { return now }
        let deficit = Double(bytes) - tokens
        let seconds = deficit / rate
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return now + Interval(nanos: UInt64(max(seconds * 1e9, 1_000)))
    }

    mutating func reset(at now: Instant) {
        tokens = Double(maxBurstBytes)
        lastRefill = now
    }
}

/// The send queues, in the Definition's priority order:
/// control > retransmissions > audio > video.
struct SendQueues {
    /// (frame, fragment index) pairs a NACK asked for.
    var retransmissions = RingBuffer<(SendFrame, UInt16)>(capacity: 256)
    var audio: [SendFrame] = []
    var video: [SendFrame] = []

    var queuedFrames: Int { audio.count + video.count }
    var queuedBytes: Int {
        var n = 0
        for f in audio { n += f.totalBytes - f.nextIndex * f.stride }
        for f in video { n += f.totalBytes - f.nextIndex * f.stride }
        return n
    }

    /// Drops everything. Called on both sides of a resume, because a resume
    /// always forces an IDR and every queued byte is stale.
    mutating func flush() {
        retransmissions.removeAll()
        audio.removeAll(keepingCapacity: true)
        video.removeAll(keepingCapacity: true)
    }
}
