import LightraySession

public struct ManualClock: MonotonicClock {
    public var instant: Instant
    public init(_ instant: Instant = .init()) { self.instant = instant }
    public func now() -> Instant { instant }
    public mutating func advance(by nanoseconds: UInt64) { instant = instant.advanced(by: nanoseconds) }
}
public struct SeededRandom {
    private var state: UInt64
    public init(seed: UInt64) { state = seed == 0 ? 1 : seed }
    public mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    public mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
}
public struct LinkModel {
    public var loss = 0.0
    public var delay: UInt64 = 2_000_000
    public var jitter: UInt64 = 0
    public var reorder = 0.0
    public var bitsPerSecond: UInt64 = 1_000_000_000
    public var queueBytes = 1_000_000
    public var enterBad = 0.0, leaveBad = 1.0, badLoss = 1.0
    public var blackout: Range<UInt64>?
    public init() {}
}
public final class SimulatedNetwork {
    private struct Delivery {
        var packet: Transmit
        var from: PeerAddress
        var at: Instant
        var order: UInt64
    }
    private var deliveries: [Delivery] = []
    private var random: SeededRandom
    private var busy: [PeerAddress: Instant] = [:]
    private var bad = false
    private var order: UInt64 = 0
    public var model: LinkModel
    public private(set) var dropped = 0
    public private(set) var peakQueuedBytes = 0
    public init(seed: UInt64 = 1, model: LinkModel = .init()) {
        random = .init(seed: seed)
        self.model = model
    }
    public func send(_ packet: Transmit, from: PeerAddress, at: Instant) {
        if random.unit() < (bad ? model.leaveBad : model.enterBad) { bad.toggle() }
        if model.blackout?.contains(at.nanoseconds) == true || random.unit() < (bad ? model.badLoss : model.loss) {
            dropped += 1
            return
        }
        let available = max(at, busy[packet.peer] ?? at)
        let queued = Int(available.elapsed(since: at) * model.bitsPerSecond / 8 / 1_000_000_000)
        guard queued + packet.bytes.count <= model.queueBytes else {
            dropped += 1
            return
        }
        peakQueuedBytes = max(peakQueuedBytes, queued + packet.bytes.count)
        let finished = available.advanced(by: UInt64(packet.bytes.count) * 8 * 1_000_000_000 / max(1, model.bitsPerSecond))
        busy[packet.peer] = finished
        let jitter = model.jitter == 0 ? 0 : random.next() % model.jitter
        let extra = random.unit() < model.reorder ? model.delay : 0
        deliveries.append(.init(packet: packet, from: from, at: finished.advanced(by: model.delay + jitter + extra), order: order))
        order += 1
    }
    public func deliver(at: Instant, _ receive: (Transmit, PeerAddress) -> Void) {
        deliveries.sort { $0.at == $1.at ? $0.order < $1.order : $0.at < $1.at }
        var count = 0
        for delivery in deliveries {
            guard delivery.at <= at else { break }
            receive(delivery.packet, delivery.from)
            count += 1
        }
        if count > 0 { deliveries.removeFirst(count) }
    }
}
public enum SyntheticFrames {
    public static func bytes(count: Int, seed: UInt8 = 1) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: $0) &+ seed } }
    public static func info(idr: Bool, captureTime: UInt32 = 0) -> FrameInfo { .init(type: idr ? .idr : .predicted, reference: idr ? .none : .previous, ltrMark: true, captureTime: captureTime, codecConfig: idr ? [0, 0, 0, 1, 64, 1, 66, 1, 68, 1] : []) }
}
