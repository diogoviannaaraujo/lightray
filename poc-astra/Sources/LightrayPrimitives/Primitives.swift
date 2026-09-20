public struct Instant: Comparable, Sendable, Hashable {
    public var nanoseconds: UInt64
    @inlinable public init(_ nanoseconds: UInt64 = 0) { self.nanoseconds = nanoseconds }
    @inlinable public static func < (lhs: Self, rhs: Self) -> Bool { lhs.nanoseconds < rhs.nanoseconds }
    @inlinable public func advanced(by delta: UInt64) -> Self { Self(nanoseconds > .max - delta ? .max : nanoseconds + delta) }
    @inlinable public func elapsed(since other: Self) -> UInt64 { nanoseconds >= other.nanoseconds ? nanoseconds - other.nanoseconds : 0 }
    @inlinable public var microseconds: UInt32 { UInt32(truncatingIfNeeded: nanoseconds / 1_000) }
}
public protocol MonotonicClock { func now() -> Instant }
public enum SerialNumber {
    @inlinable public static func isNewer(_ a: UInt32, than b: UInt32) -> Bool { a != b && (a &- b) < 0x8000_0000 }
}
public struct RingBuffer<Element> {
    private var storage: [Element?]
    private var head = 0
    public private(set) var count = 0
    public var capacity: Int { storage.count }
    public init(capacity: Int) {
        precondition(capacity > 0)
        storage = .init(repeating: nil, count: capacity)
    }
    @discardableResult public mutating func append(_ element: Element) -> Bool {
        guard count < capacity else { return false }
        storage[(head + count) % capacity] = element
        count += 1
        return true
    }
    public mutating func popFirst() -> Element? {
        guard count > 0 else { return nil }
        let value = storage[head]
        storage[head] = nil
        head = (head + 1) % capacity
        count -= 1
        return value
    }
    public var first: Element? { count > 0 ? storage[head] : nil }
    public mutating func removeAll() { while popFirst() != nil {} }
}
/// Fixed-capacity storage; a lease returns memory to its owning pool on release.
public final class BufferPool {
    public let bufferSize: Int
    private var free: [UnsafeMutableRawPointer]
    public var available: Int { free.count }
    public init(bufferSize: Int, capacity: Int) {
        precondition(bufferSize > 0 && capacity > 0)
        self.bufferSize = bufferSize
        free = (0..<capacity).map { _ in .allocate(byteCount: bufferSize, alignment: 16) }
    }
    deinit { for pointer in free { pointer.deallocate() } }
    public func acquire() -> Lease? {
        guard let pointer = free.popLast() else { return nil }
        return Lease(pool: self, pointer: pointer)
    }
    public final class Lease {
        private let pool: BufferPool
        public let pointer: UnsafeMutableRawPointer
        public var capacity: Int { pool.bufferSize }
        fileprivate init(pool: BufferPool, pointer: UnsafeMutableRawPointer) {
            self.pool = pool
            self.pointer = pointer
        }
        deinit { pool.free.append(pointer) }
        public func withBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R { try body(.init(start: pointer, count: capacity)) }
    }
}

public struct Duration: Comparable, Sendable, Hashable {
    public var nanoseconds: UInt64
    @inlinable public init(nanoseconds: UInt64) { self.nanoseconds = nanoseconds }
    @inlinable public static func < (lhs: Self, rhs: Self) -> Bool { lhs.nanoseconds < rhs.nanoseconds }
}
extension Instant {
    @inlinable public func advanced(by duration: Duration) -> Self { advanced(by: duration.nanoseconds) }
}
