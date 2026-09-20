// Chunk codecs. Each chunk is `type:u8, length:u16, body`, and unknown types are
// skipped, so a future version can add chunks without a version bump.

extension ByteWriter {
    /// Writes a chunk type plus a placeholder length; returns the patch site.
    @inlinable
    public mutating func beginChunk(_ type: ChunkType) throws(WireError) -> Int {
        try put(type.rawValue)
        return try reserve(2)
    }

    @inlinable
    public mutating func endChunk(_ lengthSite: Int) {
        patch(UInt16(offset - lengthSite - 2), at: lengthSite)
    }
}

extension ByteReader {
    /// The next chunk, or nil at the end of the chunk sequence.
    @inlinable @_lifetime(copy self)
    public mutating func nextChunk() throws(WireError) -> RawChunk? {
        // Trailing zero padding inside a protected packet reads as a run of
        // zero-type chunks; treat a zero type byte as the end of the sequence.
        guard remaining >= Wire.chunkHeaderSize else {
            // Fewer than 3 bytes left can only be padding.
            offset = bytes.byteCount
            return nil
        }
        let type = try u8()
        if type == 0 { offset = bytes.byteCount; return nil }
        let len = Int(try u16())
        return RawChunk(type: type, body: try take(len))
    }
}

public struct RawChunk: ~Escapable {
    public var type: UInt8
    public var body: RawSpan

    @inlinable @_lifetime(copy body)
    public init(type: UInt8, body: RawSpan) { self.type = type; self.body = body }

    @inlinable public var knownType: ChunkType? { ChunkType(rawValue: type) }
}

// MARK: - MEDIA_FRAGMENT 0x01

/// `stream, flags, frame_id, index, count, stride, ext_len, ext TLVs`, then payload.
///
/// `stride` is on the wire so the receiver can place any fragment at
/// `index × stride` straight into one contiguous buffer — including a last
/// fragment that arrives before any other, and across a mid-session
/// `MAX_DATAGRAM_SIZE` change.
public struct FragmentHeader: Equatable, Sendable {
    public var stream: UInt8
    public var flags: FragmentFlags
    public var frameID: UInt32
    public var index: UInt16
    public var count: UInt16
    public var stride: UInt16
    /// v0 always writes FEC scheme NONE; the field exists so a receiver can
    /// reject a scheme it does not implement.
    public var fecScheme: UInt8

    @inlinable
    public init(stream: UInt8, flags: FragmentFlags, frameID: UInt32, index: UInt16, count: UInt16,
                stride: UInt16, fecScheme: UInt8 = 0) {
        self.stream = stream; self.flags = flags; self.frameID = frameID
        self.index = index; self.count = count; self.stride = stride; self.fecScheme = fecScheme
    }

    @inlinable
    public func encode(into w: inout ByteWriter) throws(WireError) {
        try w.put(stream)
        try w.put(flags.rawValue)
        try w.put(frameID)
        try w.put(index)
        try w.put(count)
        try w.put(stride)
        try w.put(UInt8(Wire.fecTLVSize))
        try w.put(UInt8(0x01))        // FEC ext TLV
        try w.put(UInt8(1))
        try w.put(fecScheme)
    }

    /// Offset of this fragment's payload inside the reassembly buffer.
    @inlinable public var payloadOffset: Int { Int(index) * Int(stride) }
}

public struct Fragment: ~Escapable {
    public var header: FragmentHeader
    public var payload: RawSpan

    @inlinable @_lifetime(copy payload)
    public init(header: FragmentHeader, payload: RawSpan) { self.header = header; self.payload = payload }
}

extension ByteReader {
    /// Parses a MEDIA_FRAGMENT body. Unknown ext TLVs are skipped (must-ignore).
    @inlinable @_lifetime(copy self)
    public mutating func fragment() throws(WireError) -> Fragment {
        let stream = try u8()
        let flags = FragmentFlags(rawValue: try u8())
        let frameID = try u32()
        let index = try u16()
        let count = try u16()
        let stride = try u16()
        guard count > 0, index < count, stride > 0 else { throw .malformed }
        var ext = ByteReader(try take(Int(try u8())))
        var fec: UInt8 = 0
        while ext.remaining > 0 {
            let t = try ext.u8()
            let l = Int(try ext.u8())
            if t == 0x01, l >= 1 {
                fec = try ext.u8()
                try ext.skip(l - 1)
            } else {
                try ext.skip(l)
            }
        }
        let h = FragmentHeader(stream: stream, flags: flags, frameID: frameID, index: index,
                               count: count, stride: stride, fecScheme: fec)
        return Fragment(header: h, payload: rest())
    }
}

// MARK: - RELIABLE 0x02 / DATAGRAM 0x03

public struct ReliableHeader: Equatable, Sendable {
    public var stream: UInt8
    public var msgSeq: UInt32
    public var segIndex: UInt16
    public var segCount: UInt16

    @inlinable
    public init(stream: UInt8, msgSeq: UInt32, segIndex: UInt16, segCount: UInt16) {
        self.stream = stream; self.msgSeq = msgSeq; self.segIndex = segIndex; self.segCount = segCount
    }

    @inlinable
    public func encode(into w: inout ByteWriter) throws(WireError) {
        try w.put(stream); try w.put(msgSeq); try w.put(segIndex); try w.put(segCount)
    }
}

public struct ReliableSegment: ~Escapable {
    public var header: ReliableHeader
    public var payload: RawSpan

    @inlinable @_lifetime(copy payload)
    public init(header: ReliableHeader, payload: RawSpan) { self.header = header; self.payload = payload }
}

extension ByteReader {
    @inlinable @_lifetime(copy self)
    public mutating func reliableSegment() throws(WireError) -> ReliableSegment {
        let h = ReliableHeader(stream: try u8(), msgSeq: try u32(), segIndex: try u16(), segCount: try u16())
        guard h.segCount > 0, h.segIndex < h.segCount else { throw .malformed }
        return ReliableSegment(header: h, payload: rest())
    }
}

// MARK: - FEEDBACK 0x10

/// `base_seq:u32, count:u16, base_arrival_us:u32`, a received bitmap, then an
/// `i16` arrival delta per received packet in 4 µs units.
///
/// One 1200-byte datagram covers at most 543 reported packets, so a high-rate
/// flow needs several feedback datagrams per report period.
public struct FeedbackHeader: Equatable, Sendable {
    public static let unit: Int64 = 4          // µs per delta unit
    public static let maxDelta: Int64 = 32_767 * 4   // ±131 ms

    public var baseSeq: UInt32
    public var count: UInt16
    public var baseArrivalMicros: UInt32

    @inlinable
    public init(baseSeq: UInt32, count: UInt16, baseArrivalMicros: UInt32) {
        self.baseSeq = baseSeq; self.count = count; self.baseArrivalMicros = baseArrivalMicros
    }

    /// Reported packets that fit in the space left in a datagram.
    @inlinable
    public static func capacity(bytesAvailable: Int) -> Int {
        // 10-byte header, then 1 bitmap bit + up to 2 delta bytes per packet.
        let usable = bytesAvailable - 10
        guard usable > 0 else { return 0 }
        return max(0, (usable * 8) / 17)
    }
}

public enum Feedback {
    /// Writes a report for `baseSeq ..< baseSeq+count`. `arrival` returns the
    /// arrival time in microseconds for a received sequence number, or nil.
    @inlinable
    public static func encode(into w: inout ByteWriter, baseSeq: UInt32, count: Int,
                              arrival: (UInt32) -> UInt32?) throws(WireError) {
        guard count > 0, count <= Int(UInt16.max) else { throw .malformed }
        var baseArrival: UInt32 = 0
        var found = false
        for i in 0..<count where !found {
            if let a = arrival(baseSeq &+ UInt32(i)) { baseArrival = a; found = true }
        }
        guard found else { throw .malformed }

        try w.put(baseSeq)
        try w.put(UInt16(count))
        try w.put(baseArrival)

        // Bitmap, MSB first within each byte.
        var byte: UInt8 = 0
        for i in 0..<count {
            if arrival(baseSeq &+ UInt32(i)) != nil { byte |= 1 << UInt8(7 - (i % 8)) }
            if i % 8 == 7 { try w.put(byte); byte = 0 }
        }
        if count % 8 != 0 { try w.put(byte) }

        // One delta per received packet, relative to the previous received one.
        var previous = Int64(baseArrival)
        for i in 0..<count {
            guard let a = arrival(baseSeq &+ UInt32(i)) else { continue }
            var delta = Int64(Int32(bitPattern: a &- UInt32(truncatingIfNeeded: previous)))
            delta = max(-FeedbackHeader.maxDelta, min(FeedbackHeader.maxDelta, delta))
            try w.put(Int16(delta / FeedbackHeader.unit))
            previous = Int64(a)
        }
    }

    /// Decodes a report, calling `onPacket` for every sequence number in the
    /// range: `arrivalMicros` is nil for a packet the peer did not receive.
    @inlinable
    public static func decode(_ r: inout ByteReader,
                              onPacket: (UInt32, UInt32?) -> Void) throws(WireError) -> FeedbackHeader {
        let h = FeedbackHeader(baseSeq: try r.u32(), count: try r.u16(), baseArrivalMicros: try r.u32())
        let n = Int(h.count)
        guard n > 0 else { throw .malformed }
        let bitmapBytes = (n + 7) / 8
        let bitmap = try r.take(bitmapBytes)

        var arrival = h.baseArrivalMicros
        var first = true
        for i in 0..<n {
            let bit = bitmap.unsafeLoad(fromUncheckedByteOffset: i / 8, as: UInt8.self) & (1 << UInt8(7 - (i % 8)))
            if bit == 0 {
                onPacket(h.baseSeq &+ UInt32(i), nil)
                continue
            }
            let raw = Int64(Int16(bitPattern: try r.u16())) * FeedbackHeader.unit
            if first {
                // The first received packet's delta is relative to base_arrival_us,
                // which is its own arrival, so it is always zero.
                arrival = h.baseArrivalMicros &+ UInt32(truncatingIfNeeded: raw)
                first = false
            } else {
                arrival = arrival &+ UInt32(truncatingIfNeeded: raw)
            }
            onPacket(h.baseSeq &+ UInt32(i), arrival)
        }
        return h
    }
}

// MARK: - NACK 0x11

/// `stream:u8`, then entries of `(frame_id:u32, first:u16, count:u16)`.
/// `count == 0` means the whole frame, because its fragment count is unknown.
public struct NackEntry: Equatable, Sendable {
    public var frameID: UInt32
    public var first: UInt16
    public var count: UInt16

    @inlinable
    public init(frameID: UInt32, first: UInt16, count: UInt16) {
        self.frameID = frameID; self.first = first; self.count = count
    }

    @inlinable public var isWholeFrame: Bool { count == 0 }
    public static let entrySize = 8
}

public enum Nack {
    @inlinable
    public static func encode(into w: inout ByteWriter, stream: UInt8, entries: some Sequence<NackEntry>) throws(WireError) {
        try w.put(stream)
        for e in entries {
            try w.put(e.frameID); try w.put(e.first); try w.put(e.count)
        }
    }

    @inlinable
    public static func decode(_ r: inout ByteReader, onEntry: (NackEntry) -> Void) throws(WireError) -> UInt8 {
        let stream = try r.u8()
        while r.remaining >= NackEntry.entrySize {
            onEntry(NackEntry(frameID: try r.u32(), first: try r.u16(), count: try r.u16()))
        }
        return stream
    }
}

// MARK: - FRAME_ACK 0x12

public struct FrameAckEntry: Equatable, Sendable {
    public var stream: UInt8
    public var frameID: UInt32
    public var status: FrameAckStatus

    @inlinable
    public init(stream: UInt8, frameID: UInt32, status: FrameAckStatus) {
        self.stream = stream; self.frameID = frameID; self.status = status
    }
    public static let entrySize = 6
}

public enum FrameAck {
    @inlinable
    public static func encode(into w: inout ByteWriter, entries: some Sequence<FrameAckEntry>) throws(WireError) {
        for e in entries {
            try w.put(e.stream); try w.put(e.frameID); try w.put(e.status.rawValue)
        }
    }

    @inlinable
    public static func decode(_ r: inout ByteReader, onEntry: (FrameAckEntry) -> Void) throws(WireError) {
        while r.remaining >= FrameAckEntry.entrySize {
            let stream = try r.u8()
            let frameID = try r.u32()
            guard let status = FrameAckStatus(rawValue: try r.u8()) else { continue }
            onEntry(FrameAckEntry(stream: stream, frameID: frameID, status: status))
        }
    }
}

// MARK: - REFRESH_REQUEST 0x13

public struct RefreshRequest: Equatable, Sendable {
    public var stream: UInt8
    public var reason: RefreshReason
    public var preferred: RefreshPreference
    public var lastGoodFrame: UInt32
    public var lostFrame: UInt32
    public var reqID: UInt32

    @inlinable
    public init(stream: UInt8, reason: RefreshReason, preferred: RefreshPreference,
                lastGoodFrame: UInt32, lostFrame: UInt32, reqID: UInt32) {
        self.stream = stream; self.reason = reason; self.preferred = preferred
        self.lastGoodFrame = lastGoodFrame; self.lostFrame = lostFrame; self.reqID = reqID
    }

    @inlinable
    public func encode(into w: inout ByteWriter) throws(WireError) {
        try w.put(stream); try w.put(reason.rawValue); try w.put(preferred.rawValue)
        try w.put(lastGoodFrame); try w.put(lostFrame); try w.put(reqID)
    }

    @inlinable
    public static func decode(_ r: inout ByteReader) throws(WireError) -> RefreshRequest {
        let stream = try r.u8()
        guard let reason = RefreshReason(rawValue: try r.u8()),
              let preferred = RefreshPreference(rawValue: try r.u8()) else { throw .malformed }
        return RefreshRequest(stream: stream, reason: reason, preferred: preferred,
                              lastGoodFrame: try r.u32(), lostFrame: try r.u32(), reqID: try r.u32())
    }
}

// MARK: - PING 0x30 / PONG 0x31 / PARK 0x32 / RESUME 0x33 / CLOSE 0x34

/// PONG carries the id it answers plus how long the responder held it, so RTT is
/// computed entirely from the initiator's clock.
public struct Pong: Equatable, Sendable {
    public var id: UInt32
    public var holdMicros: UInt32

    @inlinable public init(id: UInt32, holdMicros: UInt32) { self.id = id; self.holdMicros = holdMicros }

    @inlinable
    public func encode(into w: inout ByteWriter) throws(WireError) { try w.put(id); try w.put(holdMicros) }

    @inlinable
    public static func decode(_ r: inout ByteReader) throws(WireError) -> Pong {
        Pong(id: try r.u32(), holdMicros: try r.u32())
    }
}
