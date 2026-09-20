import LightrayPrimitives
import LightrayWire

public struct NackPolicy: Sendable {
    public var reorderWindow: UInt64 = 1_000_000
    public var deadline: UInt64 = 50_000_000
    public init() {}
    public func retry(srtt: UInt64) -> UInt64 { max(2_000_000, srtt + srtt / 2) }
}
public final class NackScheduler {
    private struct Pending {
        var started: Instant
        var next: Instant
    }
    private var pending: [UInt64: Pending] = [:]
    private var latest: [UInt8: UInt32] = [:]
    public var policy: NackPolicy
    public init(policy: NackPolicy = .init()) { self.policy = policy }
    private func key(_ s: UInt8, _ id: UInt32) -> UInt64 { UInt64(s) << 32 | UInt64(id) }
    public func observe(stream: UInt8, frameID: UInt32, at: Instant) {
        if let last = latest[stream], SerialNumber.isNewer(frameID, than: last) {
            let gap = frameID &- last
            if gap <= 128 { for i in 1..<gap { add(stream, last &+ i, at) } }
        }
        if latest[stream] == nil || SerialNumber.isNewer(frameID, than: latest[stream]!) { latest[stream] = frameID }
        add(stream, frameID, at)
    }
    private func add(_ stream: UInt8, _ id: UInt32, _ now: Instant) {
        let k = key(stream, id)
        if pending[k] == nil, pending.count < 256 { pending[k] = .init(started: now, next: now.advanced(by: max(1_000_000, policy.reorderWindow))) }
    }
    public func complete(stream: UInt8, frameID: UInt32) { pending.removeValue(forKey: key(stream, frameID)) }
    public func poll(at: Instant, srtt: UInt64) -> (nacks: [(UInt8, UInt32)], expired: [(UInt8, UInt32)]) {
        var nacks: [(UInt8, UInt32)] = []
        var expired: [(UInt8, UInt32)] = []
        for (key, value) in pending {
            let pair = (UInt8(key >> 32), UInt32(truncatingIfNeeded: key))
            if at.elapsed(since: value.started) >= policy.deadline {
                expired.append(pair)
                pending.removeValue(forKey: key)
            } else if at >= value.next {
                nacks.append(pair)
                pending[key]?.next = at.advanced(by: policy.retry(srtt: srtt))
            }
        }
        return (nacks, expired)
    }
    public func removeAll() {
        pending.removeAll(keepingCapacity: true)
        latest.removeAll(keepingCapacity: true)
    }
}
public final class RetransmitStore {
    public struct Stored {
        public var stream: UInt8
        public var id: UInt32
        public var bytes: StoredFrame
        public var stride: Int
        public var at: Instant
    }
    private var frames: [Stored] = []
    private var lastRetransmit: [UInt64: Instant] = [:]
    public private(set) var byteCount = 0
    public var maxBytes: Int
    public var lifetime: UInt64 = 500_000_000
    public init(maxBytes: Int = 16 * 1024 * 1024) { self.maxBytes = maxBytes }
    public func insert(_ value: Stored) {
        guard value.bytes.count <= maxBytes else { return }
        expire(at: value.at)
        while byteCount + value.bytes.count > maxBytes, !frames.isEmpty { byteCount -= frames.removeFirst().bytes.count }
        frames.append(value)
        byteCount += value.bytes.count
    }
    public func store(stream: UInt8, id: UInt32, bytes: StoredFrame, stride: Int, at: Instant) { insert(.init(stream: stream, id: id, bytes: bytes, stride: stride, at: at)) }
    public func get(stream: UInt8, id: UInt32) -> Stored? { frames.first { $0.stream == stream && $0.id == id } }
    public func shouldRetransmit(stream: UInt8, id: UInt32, index: UInt16, at: Instant, srtt: UInt64) -> Bool {
        let key = UInt64(stream) << 56 | UInt64(id) << 16 | UInt64(index)
        if let last = lastRetransmit[key], at.elapsed(since: last) < srtt / 2 { return false }
        if lastRetransmit.count > 65536 { lastRetransmit.removeAll(keepingCapacity: true) }
        lastRetransmit[key] = at
        return true
    }
    public func expire(at: Instant) {
        while let first = frames.first, at.elapsed(since: first.at) >= lifetime { byteCount -= frames.removeFirst().bytes.count }
        lastRetransmit = lastRetransmit.filter { at.elapsed(since: $0.value) < lifetime }
    }
    public func removeAll() {
        frames.removeAll()
        lastRetransmit.removeAll()
        byteCount = 0
    }
}
public enum PacketPriority: Int, Sendable { case control, retransmission, audio, video }
public protocol PacingPolicy { func rate(targetBitrate: UInt32, frameBytes: Int, interval: UInt64) -> Double }
public struct FrameSpreadingPolicy: PacingPolicy {
    public var gain = 1.1
    public var linkRateCeiling = 2_000_000_000.0
    public init() {}
    public func rate(targetBitrate: UInt32, frameBytes: Int, interval: UInt64) -> Double { min(linkRateCeiling / 8, max(gain * Double(targetBitrate) / 8, Double(frameBytes) * 1e9 / Double(max(1, interval)))) }
}
public final class Pacer {
    public struct Item {
        public var bytes: [UInt8]
        public var priority: PacketPriority
        public var queuedAt: Instant
    }
    private var queues: [RingBuffer<Item>]
    private var tokens: Double
    private var updated: Instant?
    public var bytesPerSecond: Double = 2_750_000
    public let maxBurstBytes: Int
    public let maxQueueBytes: Int
    public private(set) var queuedBytes = 0
    public init(maxBurstBytes: Int = 256_000, maxQueueBytes: Int = 16 * 1024 * 1024) {
        self.maxBurstBytes = maxBurstBytes
        self.maxQueueBytes = maxQueueBytes
        tokens = Double(maxBurstBytes)
        queues = (0..<4).map { _ in RingBuffer(capacity: 16384) }
    }
    public func enqueue(_ bytes: [UInt8], priority: PacketPriority, at: Instant) throws {
        guard queuedBytes + bytes.count <= maxQueueBytes, queues[priority.rawValue].append(.init(bytes: bytes, priority: priority, queuedAt: at)) else { throw WireError.overflow }
        queuedBytes += bytes.count
    }
    public func poll(at: Instant) -> [UInt8]? {
        if let updated { tokens = min(Double(maxBurstBytes), tokens + Double(at.elapsed(since: updated)) * bytesPerSecond / 1e9) }
        updated = at
        for index in 0..<4 {
            guard let item = queues[index].first else { continue }
            let cost = item.bytes.count + 32
            guard Double(cost) <= tokens else { return nil }
            tokens -= Double(cost)
            queuedBytes -= item.bytes.count
            return queues[index].popFirst()?.bytes
        }
        return nil
    }
    public func removeAll() {
        for i in queues.indices { queues[i].removeAll() }
        queuedBytes = 0
        tokens = Double(maxBurstBytes)
        updated = nil
    }
}
public struct BitrateController {
    public private(set) var target: UInt32
    public var floor: UInt32
    public var threshold = 0.1
    public var requiredWindows = 4
    public private(set) var backstop = false
    private var consecutive = 0
    public init(target: UInt32 = 20_000_000, floor: UInt32 = 5_000_000) {
        self.target = target
        self.floor = floor
    }
    public mutating func recordWindow(received: Int, lost: Int) -> Bool {
        guard received + lost > 0 else { return false }
        consecutive = Double(lost) / Double(received + lost) > threshold ? consecutive + 1 : 0
        guard consecutive >= requiredWindows, !backstop else { return false }
        backstop = true
        target = floor
        return true
    }
    public mutating func setTarget(_ value: UInt32) {
        target = max(floor, value)
        backstop = false
        consecutive = 0
    }
}
public struct SentPacketLog {
    public struct Entry: Sendable {
        public var number: UInt64
        public var at: Instant
        public var bytes: Int
    }
    private var entries: [Entry?]
    public init(capacity: Int = 8192) {
        precondition(capacity > 0)
        entries = .init(repeating: nil, count: capacity)
    }
    public mutating func record(number: UInt64, at: Instant, bytes: Int) { entries[Int(number % UInt64(entries.count))] = .init(number: number, at: at, bytes: bytes) }
    public func entry(number: UInt64) -> Entry? {
        let entry = entries[Int(number % UInt64(entries.count))]
        return entry?.number == number ? entry : nil
    }
}
