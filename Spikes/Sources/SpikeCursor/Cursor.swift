// Spike 1: a ~Escapable RawSpan read cursor, an OutputRawSpan-based writer, and
// the v0 protected header + MEDIA_FRAGMENT codec written against them.

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

// MARK: - Codec

public struct PacketHeader: Equatable, Sendable {
    public static let size = 16
    public var flags: UInt8
    public var sessionID: UInt32
    public var transportSeq: UInt32
    public var sendTimeUs: UInt32

    @inlinable
    public init(flags: UInt8, sessionID: UInt32, transportSeq: UInt32, sendTimeUs: UInt32) {
        self.flags = flags; self.sessionID = sessionID
        self.transportSeq = transportSeq; self.sendTimeUs = sendTimeUs
    }

    @inlinable
    public static func decode(_ r: inout ByteReader) throws(WireError) -> PacketHeader {
        let flags = try r.u8()
        guard flags & 0x80 == 0 else { throw .malformed }
        try r.skip(3)
        return PacketHeader(flags: flags, sessionID: try r.u32(), transportSeq: try r.u32(), sendTimeUs: try r.u32())
    }

    @inlinable @_lifetime(w: copy w)
    public func encode(into w: inout OutputRawSpan) throws(WireError) {
        try w.put(flags); try w.put(UInt8(0)); try w.put(UInt16(0))
        try w.put(sessionID); try w.put(transportSeq); try w.put(sendTimeUs)
    }
}

public struct FragmentHeader: Equatable, Sendable {
    /// stream, flags, frame_id, index, count, ext_len + FEC TLV {0x01, 1, NONE}
    public static let sizeWithFECTLV = 11 + 3
    public var stream: UInt8
    public var flags: UInt8
    public var frameID: UInt32
    public var index: UInt16
    public var count: UInt16
    public var fecScheme: UInt8

    @inlinable
    public init(stream: UInt8, flags: UInt8, frameID: UInt32, index: UInt16, count: UInt16, fecScheme: UInt8 = 0) {
        self.stream = stream; self.flags = flags; self.frameID = frameID
        self.index = index; self.count = count; self.fecScheme = fecScheme
    }

    @inlinable @_lifetime(w: copy w)
    public func encode(into w: inout OutputRawSpan) throws(WireError) {
        try w.put(stream); try w.put(flags); try w.put(frameID); try w.put(index); try w.put(count)
        try w.put(UInt8(3)); try w.put(UInt8(0x01)); try w.put(UInt8(1)); try w.put(fecScheme)
    }
}

public struct Chunk: ~Escapable {
    public var type: UInt8
    public var body: RawSpan

    @inlinable @_lifetime(copy body)
    public init(type: UInt8, body: RawSpan) { self.type = type; self.body = body }
}

public struct Fragment: ~Escapable {
    public var header: FragmentHeader
    public var payload: RawSpan

    @inlinable @_lifetime(copy payload)
    public init(header: FragmentHeader, payload: RawSpan) { self.header = header; self.payload = payload }
}

extension ByteReader {
    /// Next `type:u8, length:u16, body` chunk, or nil at the end.
    @inlinable @_lifetime(copy self)
    public mutating func nextChunk() throws(WireError) -> Chunk? {
        guard remaining > 0 else { return nil }
        let type = try u8()
        let len = Int(try u16())
        return Chunk(type: type, body: try take(len))
    }

    /// MEDIA_FRAGMENT body. Unknown ext TLVs are skipped (must-ignore).
    @inlinable @_lifetime(copy self)
    public mutating func fragment() throws(WireError) -> Fragment {
        let stream = try u8(), flags = try u8(), frameID = try u32()
        let index = try u16(), count = try u16()
        guard count == 0 || index < count else { throw .malformed }
        var ext = ByteReader(try take(Int(try u8())))
        var fec: UInt8 = 0
        while ext.remaining > 0 {
            let t = try ext.u8(), l = Int(try ext.u8())
            if t == 0x01, l >= 1 { fec = try ext.u8(); try ext.skip(l - 1) } else { try ext.skip(l) }
        }
        let h = FragmentHeader(stream: stream, flags: flags, frameID: frameID, index: index, count: count, fecScheme: fec)
        return Fragment(header: h, payload: rest())
    }
}
