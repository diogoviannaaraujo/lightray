import LightrayCore

/// Holds recently sent frames so a NACK can be answered without the app
/// re-encoding. Bounded by both age and bytes; Phase 0 noted the byte cap wins
/// above about 270 Mbps, which still leaves far more than a frame deadline.
///
/// Storing whole frames rather than per-fragment copies means a retransmit costs
/// no extra memory: the fragment is re-derived from the frame the app already
/// handed over.
struct RetransmitStore {
    private var frames: [SendFrame] = []
    private(set) var bytesHeld = 0
    var duration: Interval
    var byteLimit: Int
    /// A retransmission of the same fragment is suppressed within srtt/2.
    private var lastSent: [UInt64: Instant] = [:]

    init(duration: Interval, byteLimit: Int) {
        self.duration = duration
        self.byteLimit = byteLimit
    }

    mutating func insert(_ frame: SendFrame) {
        frames.append(frame)
        bytesHeld += frame.totalBytes
        trim(now: frame.submittedAt)
    }

    mutating func trim(now: Instant) {
        while let first = frames.first,
              now - first.submittedAt > duration || bytesHeld > byteLimit {
            bytesHeld -= first.totalBytes
            for i in 0..<first.fragmentCount { lastSent[key(first.frameID, UInt16(i))] = nil }
            frames.removeFirst()
        }
    }

    func frame(_ stream: UInt8, _ frameID: UInt32) -> SendFrame? {
        frames.last { $0.stream == stream && $0.frameID == frameID }
    }

    /// Newest frame id held for a stream, so a NACK for something already
    /// evicted can be answered with a refresh instead.
    func newestFrameID(_ stream: UInt8) -> UInt32? {
        frames.last { $0.stream == stream }?.frameID
    }

    private func key(_ frameID: UInt32, _ index: UInt16) -> UInt64 {
        UInt64(frameID) << 16 | UInt64(index)
    }

    /// True when this fragment may be retransmitted now, recording the attempt.
    mutating func shouldRetransmit(frameID: UInt32, index: UInt16, now: Instant, srtt: Interval) -> Bool {
        let k = key(frameID, index)
        if let last = lastSent[k], now - last < srtt / 2 { return false }
        lastSent[k] = now
        return true
    }

    /// Releases everything. The host calls this the moment it parks a session:
    /// none of it can reach an absent peer, and a resume forces an IDR that
    /// would discard it anyway.
    mutating func removeAll() {
        frames.removeAll(keepingCapacity: false)
        lastSent.removeAll(keepingCapacity: false)
        bytesHeld = 0
    }

    var frameCount: Int { frames.count }
}
