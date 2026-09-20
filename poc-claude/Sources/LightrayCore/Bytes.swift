public enum WireError: Error, Equatable, Sendable {
    case truncated
    case malformed
    case overflow
    case unsupportedVersion(UInt8)
}

// MARK: - Reader

/// A bounds-checked read cursor over a borrowed `RawSpan`.
///
/// `~Escapable` so it can never outlive the datagram it reads. Every accessor is
/// `@inlinable` because parsing is the hot path: Phase-0 measured 15.8 ns for a
/// header plus fragment parse through this cursor, against a 250 ns budget.
public struct ByteReader: ~Escapable {
    public let bytes: RawSpan
    public var offset: Int

    @inlinable @_lifetime(copy bytes)
    public init(_ bytes: RawSpan) {
        self.bytes = bytes
        self.offset = 0
    }

    @inlinable public var remaining: Int { bytes.byteCount &- offset }
    @inlinable public var isEmpty: Bool { remaining == 0 }

    @inlinable
    public mutating func u8() throws(WireError) -> UInt8 {
        guard offset < bytes.byteCount else { throw .truncated }
        let v = bytes.unsafeLoad(fromUncheckedByteOffset: offset, as: UInt8.self)
        offset &+= 1
        return v
    }

    @inlinable
    public mutating func u16() throws(WireError) -> UInt16 {
        guard remaining >= 2 else { throw .truncated }
        let v = bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: UInt16.self)
        offset &+= 2
        return UInt16(bigEndian: v)
    }

    @inlinable
    public mutating func u32() throws(WireError) -> UInt32 {
        guard remaining >= 4 else { throw .truncated }
        let v = bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: UInt32.self)
        offset &+= 4
        return UInt32(bigEndian: v)
    }

    @inlinable
    public mutating func u64() throws(WireError) -> UInt64 {
        guard remaining >= 8 else { throw .truncated }
        let v = bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: UInt64.self)
        offset &+= 8
        return UInt64(bigEndian: v)
    }

    @inlinable @_lifetime(self: copy self)
    public mutating func skip(_ n: Int) throws(WireError) {
        guard n >= 0, remaining >= n else { throw .truncated }
        offset &+= n
    }

    @inlinable @_lifetime(copy self)
    public mutating func take(_ n: Int) throws(WireError) -> RawSpan {
        guard n >= 0, remaining >= n else { throw .truncated }
        let s = bytes.extracting(unchecked: offset..<(offset &+ n))
        offset &+= n
        return s
    }

    @inlinable @_lifetime(copy self)
    public mutating func rest() -> RawSpan {
        let s = bytes.extracting(unchecked: offset..<bytes.byteCount)
        offset = bytes.byteCount
        return s
    }

    /// Reads `n` bytes into `dst`, which must have room. Used for keys and tokens,
    /// never per packet.
    @inlinable @_lifetime(self: copy self)
    public mutating func copy(_ n: Int, into dst: UnsafeMutableRawBufferPointer) throws(WireError) {
        guard n >= 0, remaining >= n, dst.count >= n else { throw .truncated }
        let src = bytes.extracting(unchecked: offset..<(offset &+ n))
        src.withUnsafeBytes { dst.copyMemory(from: $0) }
        offset &+= n
    }

    /// Reads `n` bytes into a fresh array. Keys, tokens and stream tables only;
    /// never per packet.
    @inlinable @_lifetime(self: copy self)
    public mutating func byteArray(_ n: Int) throws(WireError) -> [UInt8] {
        guard n >= 0, remaining >= n else { throw .truncated }
        var out = [UInt8](repeating: 0, count: n)
        let src = bytes.extracting(unchecked: offset..<(offset &+ n))
        out.withUnsafeMutableBytes { dst in src.withUnsafeBytes { dst.copyMemory(from: $0) } }
        offset &+= n
        return out
    }
}

// MARK: - Writer

/// A bounded writer over caller-owned memory. Escapable, so it threads freely
/// through the fragmenter and chunk writers; overflow throws instead of trapping,
/// because a datagram running out of room is an ordinary control-flow event.
public struct ByteWriter: ~Copyable {
    public let buffer: UnsafeMutableRawBufferPointer
    public var offset: Int

    @inlinable
    public init(_ buffer: UnsafeMutableRawBufferPointer, offset: Int = 0) {
        self.buffer = buffer
        self.offset = offset
    }

    @inlinable public var freeCapacity: Int { buffer.count &- offset }
    @inlinable public var written: Int { offset }

    /// The bytes written so far.
    @inlinable public var contents: UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(rebasing: buffer[..<offset])
    }

    @inlinable
    public mutating func put<T: FixedWidthInteger & BitwiseCopyable>(_ v: T) throws(WireError) {
        guard freeCapacity >= MemoryLayout<T>.size else { throw .overflow }
        buffer.storeBytes(of: v.bigEndian, toByteOffset: offset, as: T.self)
        offset &+= MemoryLayout<T>.size
    }

    @inlinable
    public mutating func put(bytes src: UnsafeRawBufferPointer) throws(WireError) {
        guard freeCapacity >= src.count else { throw .overflow }
        if src.count > 0 {
            UnsafeMutableRawBufferPointer(rebasing: buffer[offset..<(offset &+ src.count)]).copyMemory(from: src)
        }
        offset &+= src.count
    }

    @inlinable
    public mutating func put(span: RawSpan) throws(WireError) {
        try span.withUnsafeBytes { (src: UnsafeRawBufferPointer) throws(WireError) in try put(bytes: src) }
    }

    /// Reserves `n` bytes and hands back where they went, so a length written
    /// before its body can be patched once the body's size is known.
    @inlinable
    public mutating func reserve(_ n: Int) throws(WireError) -> Int {
        guard freeCapacity >= n else { throw .overflow }
        let at = offset
        offset &+= n
        return at
    }

    @inlinable
    public mutating func patch<T: FixedWidthInteger & BitwiseCopyable>(_ v: T, at index: Int) {
        buffer.storeBytes(of: v.bigEndian, toByteOffset: index, as: T.self)
    }

    /// Writes `n` bytes of zero padding — how INIT reaches `max_datagram_size`.
    @inlinable
    public mutating func pad(to total: Int) throws(WireError) {
        guard total <= buffer.count else { throw .overflow }
        guard total > offset else { return }
        UnsafeMutableRawBufferPointer(rebasing: buffer[offset..<total]).initializeMemory(as: UInt8.self, repeating: 0)
        offset = total
    }


    @inlinable
    public mutating func put(_ array: [UInt8]) throws(WireError) {
        guard freeCapacity >= array.count else { throw .overflow }
        let at = offset
        array.withUnsafeBytes { src in
            if src.count > 0 {
                UnsafeMutableRawBufferPointer(rebasing: buffer[at..<(at &+ src.count)]).copyMemory(from: src)
            }
        }
        offset &+= array.count
    }

    @inlinable public mutating func rewind(to index: Int) { offset = index }
}
