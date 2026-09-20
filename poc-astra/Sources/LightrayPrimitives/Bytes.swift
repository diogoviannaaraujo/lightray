public enum WireError: Error, Equatable, Sendable {
    case truncated
    case malformed
    case overflow
}

// MARK: - Reader

public struct ByteReader: ~Escapable {
    public let bytes: RawSpan
    public var offset: Int

    @inlinable @_lifetime(copy bytes)
    public init(_ bytes: RawSpan) {
        self.bytes = bytes
        self.offset = 0
    }

    @inlinable public var remaining: Int { bytes.byteCount &- offset }

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
}

// MARK: - Writer (bounded; throws instead of trapping on overflow)

extension OutputRawSpan {
    @inlinable @_lifetime(self: copy self)
    public mutating func put<T: FixedWidthInteger & BitwiseCopyable>(_ v: T) throws(WireError) {
        guard freeCapacity >= MemoryLayout<T>.size else { throw .overflow }
        append(v.bigEndian, as: T.self)
    }
}
