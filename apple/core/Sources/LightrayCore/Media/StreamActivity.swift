/// A client observation of successful decodes, independent of the host's capture state.
public struct StreamActivity: Sendable {
    public enum State: String, Sendable { case waiting, live, interrupted }
    public private(set) var state: State = .waiting
    private var previousCount = 0
    private var lastProgress: UInt64?
    private var lastObservation: UInt64?
    public static let staleMicros: UInt64 = 2_000_000
    public init() {}

    @discardableResult
    public mutating func observe(decodedCount: Int, now: UInt64) -> State {
        if decodedCount < previousCount || (lastObservation.map { now < $0 } ?? false) {
            self = StreamActivity()
            previousCount = decodedCount
            lastObservation = now
            return state
        }
        lastObservation = now
        if decodedCount > previousCount {
            lastProgress = now
            state = .live
        } else if let lastProgress, now - lastProgress >= Self.staleMicros {
            state = .interrupted
        }
        previousCount = decodedCount
        return state
    }
}
