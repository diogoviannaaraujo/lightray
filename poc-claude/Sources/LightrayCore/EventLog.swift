/// One entry on the park/resume/rebind/refresh timeline.
public struct TimelineEvent: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case handshake, adopted, established
        case park, idle, resumed, expired, rebind
        case refreshRequested, refreshSent, keyframeDelivered
        case sessionUnknown, sessionLost, backstop, reconfigure, close
    }
    public var at: Instant
    public var kind: Kind
    public var detail: UInt32

    public init(at: Instant, kind: Kind, detail: UInt32 = 0) {
        self.at = at; self.kind = kind; self.detail = detail
    }
}

/// A fixed-capacity ring of timeline events. Overwrites the oldest entry, so a
/// long-running session never grows and never allocates after construction.
public struct EventLog: Sendable {
    private var storage: [TimelineEvent?]
    private var next = 0
    public private(set) var totalRecorded = 0

    public init(capacity: Int = 128) {
        storage = [TimelineEvent?](repeating: nil, count: max(capacity, 1))
    }

    public mutating func record(_ e: TimelineEvent) {
        storage[next] = e
        next = (next + 1) % storage.count
        totalRecorded += 1
    }

    public mutating func record(_ kind: TimelineEvent.Kind, at: Instant, detail: UInt32 = 0) {
        record(TimelineEvent(at: at, kind: kind, detail: detail))
    }

    /// Oldest first.
    public var events: [TimelineEvent] {
        var out: [TimelineEvent] = []
        out.reserveCapacity(min(totalRecorded, storage.count))
        let n = storage.count
        let start = totalRecorded >= n ? next : 0
        for i in 0..<min(totalRecorded, n) {
            if let e = storage[(start + i) % n] { out.append(e) }
        }
        return out
    }
}

/// A fixed-capacity FIFO ring used for event and command queues inside the
/// engines. Grows only if it is asked to hold more than its capacity.
public struct RingBuffer<Element> {
    private var storage: [Element?]
    private var head = 0
    private var tail = 0
    public private(set) var count = 0

    public init(capacity: Int) {
        storage = [Element?](repeating: nil, count: max(capacity, 1))
    }

    public var isEmpty: Bool { count == 0 }
    public var capacity: Int { storage.count }

    public mutating func push(_ e: Element) {
        if count == storage.count { grow() }
        storage[tail] = e
        tail = (tail + 1) % storage.count
        count += 1
    }

    public mutating func pop() -> Element? {
        guard count > 0 else { return nil }
        let e = storage[head]
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        return e
    }

    public var first: Element? { count > 0 ? storage[head] : nil }

    public mutating func removeAll() {
        for i in 0..<storage.count { storage[i] = nil }
        head = 0; tail = 0; count = 0
    }

    private mutating func grow() {
        var new = [Element?](repeating: nil, count: storage.count * 2)
        for i in 0..<count { new[i] = storage[(head + i) % storage.count] }
        storage = new
        head = 0
        tail = count
    }
}
