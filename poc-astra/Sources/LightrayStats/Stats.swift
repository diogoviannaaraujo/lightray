import LightrayPrimitives

public struct Histogram: Sendable {
    private var bins = InlineArray<64, UInt64>(repeating: 0)
    public private(set) var count: UInt64 = 0
    public init() {}
    public mutating func record(_ value: UInt64) {
        let index = value == 0 ? 0 : 63 - value.leadingZeroBitCount
        bins[index] &+= 1
        count &+= 1
    }
    public func percentile(_ fraction: Double) -> UInt64 {
        guard count > 0 else { return 0 }
        let target = max(1, UInt64(Double(count) * min(1, max(0, fraction))))
        var sum: UInt64 = 0
        for i in 0..<64 {
            sum += bins[i]
            if sum >= target { return UInt64(1) << i }
        }
        return .max
    }
}
public struct PathStats: Sendable {
    public var sent: UInt64 = 0, received: UInt64 = 0, bytesSent: UInt64 = 0, bytesReceived: UInt64 = 0
    public var malformed: UInt64 = 0, authenticationFailures: UInt64 = 0, duplicates: UInt64 = 0, reordered: UInt64 = 0, lost: UInt64 = 0
    public var srtt: Double = 4_000_000, rttvar: Double = 2_000_000, jitter: Double = 0, queuingDelay: Double = 0
    private var transit: Int64?
    private var minimumTransit: Int64 = .max
    public init() {}
    public mutating func recordRTT(_ ns: UInt64) {
        let sample = Double(ns)
        rttvar += (abs(srtt - sample) - rttvar) / 4
        srtt += (sample - srtt) / 8
    }
    public mutating func recordArrival(sendTime: UInt32, at now: Instant) {
        let current = Int64(Int32(bitPattern: now.microseconds &- sendTime)) * 1000
        if let transit { jitter += (Double(abs(current - transit)) - jitter) / 16 }
        transit = current
        minimumTransit = min(minimumTransit, current)
        queuingDelay = Double(current - minimumTransit)
    }
}
public struct StreamStats: Sendable {
    public var submitted: UInt64 = 0, completed: UInt64 = 0, dropped: UInt64 = 0, nacks: UInt64 = 0, retransmits: UInt64 = 0
    public var frameAcksSent: UInt64 = 0
    public var completionLatency = Histogram()
    public init() {}
}
public struct ReconnectStats: Sendable {
    public var parks: UInt64 = 0, resumes: UInt64 = 0, rebinds: UInt64 = 0
    public var resumeLatency = Histogram()
    public init() {}
}
public enum TimelineKind: UInt8, Sendable { case connected, parked, idle, resumed, rebound, refresh, expired, closed }
public struct TimelineEvent: Sendable {
    public var kind: TimelineKind
    public var at: Instant
    public init(_ kind: TimelineKind, at: Instant) {
        self.kind = kind
        self.at = at
    }
}
public struct EventLog: Sendable {
    private var entries = InlineArray<64, TimelineEvent?>(repeating: nil)
    public private(set) var count = 0
    private var head = 0
    public init() {}
    public mutating func append(_ event: TimelineEvent) {
        entries[head] = event
        head = (head + 1) % 64
        count = min(64, count + 1)
    }
    public var events: [TimelineEvent] { (0..<count).compactMap { entries[(head - count + $0 + 64) % 64] } }
}
public enum LinkQuality: String, Sendable { case good, degraded, poor }
public struct StatsSnapshot: Sendable {
    public var path = PathStats()
    public var streams = StreamStats()
    public var reconnect = ReconnectStats()
    public var timeline = EventLog()
    public var pacerBytes = 0
    public var backstop = false
    public var bitrate: UInt32 = 20_000_000
    public init() {}
    public var quality: LinkQuality { backstop || path.srtt > 100_000_000 ? .poor : path.queuingDelay > 10_000_000 || path.jitter > 5_000_000 ? .degraded : .good }
}
