import Darwin

/// Fixed-size MTU slabs plus size-classed large buffers for whole frames.
///
/// Every datagram the runtime sends or receives comes from here, so the steady
/// state allocates nothing. Not thread-safe: each pool belongs to one loop thread.
public final class BufferPool {
    public let slabSize: Int
    private var free: [UnsafeMutableRawBufferPointer] = []
    private var allocatedSlabs = 0
    private let maxSlabs: Int

    /// Size-classed spares for frame reassembly, keyed by power-of-two class.
    private var largeFree: [Int: [UnsafeMutableRawBufferPointer]] = [:]
    public private(set) var largeBytesHeld = 0
    private let largeBytesLimit: Int

    public init(slabSize: Int = 2048, maxSlabs: Int = 4096, largeBytesLimit: Int = 64 << 20) {
        self.slabSize = slabSize
        self.maxSlabs = maxSlabs
        self.largeBytesLimit = largeBytesLimit
    }

    deinit {
        for b in free { b.deallocate() }
        for (_, list) in largeFree { for b in list { b.deallocate() } }
    }

    /// An MTU-sized slab. Returns nil only when the pool's hard cap is reached,
    /// which the runtime treats as backpressure rather than a fatal error.
    public func takeSlab() -> UnsafeMutableRawBufferPointer? {
        if let b = free.popLast() { return b }
        guard allocatedSlabs < maxSlabs else { return nil }
        allocatedSlabs += 1
        return UnsafeMutableRawBufferPointer.allocate(byteCount: slabSize, alignment: 64)
    }

    public func giveBack(_ b: UnsafeMutableRawBufferPointer) {
        precondition(b.count == slabSize, "slab returned to the wrong pool")
        free.append(b)
    }

    // MARK: Large buffers

    @inlinable public static func sizeClass(for n: Int) -> Int {
        var c = 4096
        while c < n { c <<= 1 }
        return c
    }

    /// A buffer of at least `byteCount`, rounded up to a power-of-two class so
    /// frames of drifting size reuse the same allocations.
    public func takeLarge(_ byteCount: Int) -> UnsafeMutableRawBufferPointer {
        let cls = Self.sizeClass(for: byteCount)
        if var list = largeFree[cls], let b = list.popLast() {
            largeFree[cls] = list
            largeBytesHeld -= cls
            return b
        }
        return UnsafeMutableRawBufferPointer.allocate(byteCount: cls, alignment: 64)
    }

    public func giveBackLarge(_ b: UnsafeMutableRawBufferPointer) {
        let cls = b.count
        guard largeBytesHeld + cls <= largeBytesLimit else { b.deallocate(); return }
        largeFree[cls, default: []].append(b)
        largeBytesHeld += cls
    }

    /// Drops every cached buffer. The host calls this when it parks a session.
    public func drain() {
        for b in free { b.deallocate() }
        free.removeAll(keepingCapacity: true)
        allocatedSlabs = 0
        for (_, list) in largeFree { for b in list { b.deallocate() } }
        largeFree.removeAll(keepingCapacity: true)
        largeBytesHeld = 0
    }

    public var slabsOutstanding: Int { allocatedSlabs - free.count }
}

/// Frame bytes the app hands to the protocol. Retained, never copied, until the
/// frame leaves the retransmit window.
public protocol ByteStorage: AnyObject, Sendable {
    var bytes: UnsafeRawBufferPointer { get }
}

/// A heap-allocated `ByteStorage` for tests, benchmarks and the demo. A real app
/// would wrap the encoder's `CMBlockBuffer` instead.
public final class HeapStorage: ByteStorage, @unchecked Sendable {
    private let buffer: UnsafeMutableRawBufferPointer
    public var bytes: UnsafeRawBufferPointer { UnsafeRawBufferPointer(buffer) }

    public init(byteCount: Int, fill: UInt8 = 0) {
        buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: byteCount, alignment: 64)
        buffer.initializeMemory(as: UInt8.self, repeating: fill)
    }

    public init(copying src: UnsafeRawBufferPointer) {
        buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(src.count, 1), alignment: 64)
        if src.count > 0 { UnsafeMutableRawBufferPointer(rebasing: buffer[..<src.count]).copyMemory(from: src) }
    }

    public init(_ bytes: [UInt8]) {
        buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(bytes.count, 1), alignment: 64)
        bytes.withUnsafeBytes { src in
            if src.count > 0 { UnsafeMutableRawBufferPointer(rebasing: buffer[..<src.count]).copyMemory(from: src) }
        }
    }

    /// Writable view, for a source that fills the storage after construction.
    public var mutableBytes: UnsafeMutableRawBufferPointer { buffer }

    deinit { buffer.deallocate() }
}
