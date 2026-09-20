import LightrayCore
import LightrayEngine

/// A discrete-event link model. Deterministic given its seed, so a scenario that
/// fails once fails the same way every time.
public final class SimulatedNetwork {
    public enum Direction: Sendable, CaseIterable {
        case hostToClient
        case clientToHost
    }

    public struct LinkModel: Sendable {
        public var delay: Interval = .milliseconds(2)
        public var jitter: Interval = .zero
        /// Independent per-packet loss.
        public var lossRate: Double = 0
        /// Gilbert–Elliott burst loss: probability of entering and leaving the
        /// bad state, and the loss rate while in it.
        public var enterBadState: Double = 0
        public var leaveBadState: Double = 0
        public var badStateLoss: Double = 1.0
        /// Fraction of packets held back and delivered after the next one.
        public var reorderRate: Double = 0
        /// A bottleneck with a drop-tail queue.
        public var bitsPerSecond: UInt64?
        public var queueCapacityBytes = 64 * 1500
        /// Nothing crosses the link between these instants.
        public var blackout: (start: Instant, end: Instant)?

        public init() {}

        public static func clean(delay: Interval = .milliseconds(2)) -> LinkModel {
            var m = LinkModel()
            m.delay = delay
            return m
        }
    }

    public struct Packet {
        public var direction: Direction
        public var bytes: [UInt8]
        public var source: PeerAddress
        public var arrivesAt: Instant
        var sequence: UInt64
    }

    public var hostToClient: LinkModel
    public var clientToHost: LinkModel

    private var inFlight: [Packet] = []
    private var random: SeededRandom
    private var sequence: UInt64 = 0
    private var inBadState: [Direction: Bool] = [.hostToClient: false, .clientToHost: false]
    /// When the bottleneck finishes draining what it already holds.
    private var queueFreeAt: [Direction: Instant] = [:]
    private var queueBytes: [Direction: Int] = [.hostToClient: 0, .clientToHost: 0]

    public private(set) var sentCount = 0
    public private(set) var droppedCount = 0
    public private(set) var deliveredCount = 0
    /// Peak bytes held in the bottleneck queue, per direction.
    public private(set) var peakQueueBytes: [Direction: Int] = [.hostToClient: 0, .clientToHost: 0]
    /// The most recent datagram offered in each direction, so a test can replay
    /// one — the shape an off-path attacker can most easily produce.
    public private(set) var lastOffered: [Direction: [UInt8]] = [:]

    public init(seed: UInt64 = 0x5EED,
                hostToClient: LinkModel = .clean(),
                clientToHost: LinkModel = .clean()) {
        self.random = SeededRandom(seed: seed)
        self.hostToClient = hostToClient
        self.clientToHost = clientToHost
    }

    public func model(_ direction: Direction) -> LinkModel {
        direction == .hostToClient ? hostToClient : clientToHost
    }

    /// Offers a datagram to the link. It may be dropped, delayed, reordered or
    /// queued behind a bottleneck.
    public func send(_ bytes: UnsafeRawBufferPointer, direction: Direction,
                     source: PeerAddress, at now: Instant) {
        sentCount += 1
        lastOffered[direction] = Array(bytes)
        let model = self.model(direction)

        if let window = model.blackout, now >= window.start, now < window.end {
            droppedCount += 1
            return
        }

        // Gilbert–Elliott: bursts, which is what actually breaks a video stream.
        if model.enterBadState > 0 || model.leaveBadState > 0 {
            let bad = inBadState[direction] ?? false
            let nowBad = bad ? !random.chance(model.leaveBadState) : random.chance(model.enterBadState)
            inBadState[direction] = nowBad
            if nowBad, random.chance(model.badStateLoss) {
                droppedCount += 1
                return
            }
        }
        if random.chance(model.lossRate) {
            droppedCount += 1
            return
        }

        var arrival = now + model.delay
        if model.jitter.nanos > 0 {
            arrival = arrival + Interval(nanos: UInt64(random.unit() * Double(model.jitter.nanos)))
        }

        // Bottleneck: serialisation delay plus a drop-tail queue.
        if let rate = model.bitsPerSecond, rate > 0 {
            let serviceTime = Interval(nanos: UInt64(Double(bytes.count * 8) * 1e9 / Double(rate)))
            let freeAt = queueFreeAt[direction] ?? now
            let startsAt = freeAt > now ? freeAt : now
            let backlog = (startsAt - now).nanos > 0
                ? Int(Double((startsAt - now).nanos) * Double(rate) / 8e9)
                : 0
            if backlog + bytes.count > model.queueCapacityBytes {
                droppedCount += 1
                return
            }
            queueBytes[direction] = backlog + bytes.count
            peakQueueBytes[direction] = max(peakQueueBytes[direction] ?? 0, backlog + bytes.count)
            let done = startsAt + serviceTime
            queueFreeAt[direction] = done
            arrival = done + model.delay
        }

        sequence += 1
        var packet = Packet(direction: direction, bytes: Array(bytes), source: source,
                            arrivesAt: arrival, sequence: sequence)
        if random.chance(model.reorderRate) {
            // Push it behind one more packet's worth of delay.
            packet.arrivesAt = packet.arrivesAt + max(model.delay, .milliseconds(1))
        }
        inFlight.append(packet)
    }

    /// Packets whose arrival time has come, in arrival order.
    public func takeDeliverable(upTo now: Instant) -> [Packet] {
        guard !inFlight.isEmpty else { return [] }
        // Cheap early-out: the pump asks on every turn of its cascade.
        guard let soonest = nextDelivery(), soonest <= now else { return [] }
        var due: [Packet] = []
        var rest: [Packet] = []
        for p in inFlight {
            if p.arrivesAt <= now { due.append(p) } else { rest.append(p) }
        }
        inFlight = rest
        due.sort { ($0.arrivesAt, $0.sequence) < ($1.arrivesAt, $1.sequence) }
        deliveredCount += due.count
        return due
    }

    public func nextDelivery() -> Instant? {
        inFlight.min { $0.arrivesAt < $1.arrivesAt }?.arrivesAt
    }

    public var inFlightCount: Int { inFlight.count }

    public func clearInFlight() { inFlight.removeAll() }
}
