// The frame header the sender logically prepends to each frame's bytes, so
// fragmentation stays payload-agnostic and zero-copy.

/// Frame-header ext TLV types.
public enum FrameExt: UInt8, Sendable {
    /// HEVC VPS + SPS + PPS, 4-byte NAL lengths. Not in-band in slice data and
    /// no decoder can be built without them, so every IDR carries its own copy:
    /// a joining or rebuilt decoder never waits on a separate message.
    case codecConfig = 0x01
    /// Reserved: an intra-refresh-complete flag. VideoToolbox has no
    /// intra-refresh property, so v0 never writes this.
    case intraRefreshComplete = 0x02
}

public struct FrameHeader: Equatable, Sendable {
    public var frameType: FrameType
    public var refKind: RefKind
    public var flags: FrameFlags
    public var configGeneration: UInt16
    public var captureTimeMicros: UInt32
    /// Present for `ref_kind == .ltr`, absent for `.ltrAny`.
    public var refFrameID: UInt32?
    /// Length of the CODEC_CONFIG payload carried in the ext TLVs, if any.
    public var codecConfigLength: Int = 0

    @inlinable
    public init(frameType: FrameType, refKind: RefKind, flags: FrameFlags = [],
                configGeneration: UInt16, captureTimeMicros: UInt32, refFrameID: UInt32? = nil) {
        self.frameType = frameType
        self.refKind = refKind
        self.flags = flags
        self.configGeneration = configGeneration
        self.captureTimeMicros = captureTimeMicros
        self.refFrameID = refFrameID
    }

    @inlinable public var isKeyframe: Bool { frameType == .idr }
    @inlinable public var ltrMarked: Bool { flags.contains(.ltrMark) }

    /// `frame_type, ref_kind, flags, config_generation, capture_time_us,
    /// [ref_frame_id if ref_kind == .ltr], ext_len:u16, ext TLVs`
    @inlinable
    public var encodedSize: Int {
        var n = 1 + 1 + 1 + 2 + 4 + 2
        if refKind == .ltr { n += 4 }
        if codecConfigLength > 0 { n += 3 + codecConfigLength }
        return n
    }

    @inlinable
    public func encode(into w: inout ByteWriter, codecConfig: UnsafeRawBufferPointer?) throws(WireError) {
        try w.put(frameType.rawValue)
        try w.put(refKind.rawValue)
        try w.put(flags.rawValue)
        try w.put(configGeneration)
        try w.put(captureTimeMicros)
        if refKind == .ltr {
            guard let id = refFrameID else { throw .malformed }
            try w.put(id)
        }
        let extLen = (codecConfig?.count ?? 0) > 0 ? 3 + codecConfig!.count : 0
        try w.put(UInt16(extLen))
        if let cfg = codecConfig, cfg.count > 0 {
            try w.put(FrameExt.codecConfig.rawValue)
            try w.put(UInt16(cfg.count))
            try w.put(bytes: cfg)
        }
    }

    /// Parses a frame header out of a reassembled frame buffer, returning byte
    /// ranges rather than spans: the receiver owns this buffer and holds it
    /// across an asynchronous decode, which a non-escapable span cannot survive.
    public static func parse(_ buf: UnsafeRawBufferPointer) throws(WireError) -> FrameLayout {
        let span = RawSpan(_unsafeBytes: buf)
        var r = ByteReader(span)
        guard let frameType = FrameType(rawValue: try r.u8()),
              let refKind = RefKind(rawValue: try r.u8()) else { throw .malformed }
        let flags = FrameFlags(rawValue: try r.u8())
        let configGeneration = try r.u16()
        let captureTime = try r.u32()
        var refFrameID: UInt32?
        if refKind == .ltr { refFrameID = try r.u32() }
        var header = FrameHeader(frameType: frameType, refKind: refKind, flags: flags,
                                 configGeneration: configGeneration, captureTimeMicros: captureTime,
                                 refFrameID: refFrameID)
        let extLen = Int(try r.u16())
        guard r.remaining >= extLen else { throw .truncated }
        let extStart = r.offset
        var config: Range<Int>? = nil
        var at = extStart
        while at + 3 <= extStart + extLen {
            let t = span.unsafeLoad(fromUncheckedByteOffset: at, as: UInt8.self)
            let l = Int(UInt16(bigEndian: span.unsafeLoadUnaligned(fromUncheckedByteOffset: at + 1, as: UInt16.self)))
            guard at + 3 + l <= extStart + extLen else { throw .truncated }
            if t == FrameExt.codecConfig.rawValue {
                config = (at + 3)..<(at + 3 + l)
                header.codecConfigLength = l
            }
            at += 3 + l   // unknown ext TLVs are skipped (must-ignore)
        }
        return FrameLayout(header: header, codecConfig: config,
                           payload: (extStart + extLen)..<buf.count)
    }
}

/// Where a parsed frame's parts sit inside the frame buffer.
public struct FrameLayout: Sendable, Equatable {
    public var header: FrameHeader
    public var codecConfig: Range<Int>?
    public var payload: Range<Int>

    public init(header: FrameHeader, codecConfig: Range<Int>?, payload: Range<Int>) {
        self.header = header; self.codecConfig = codecConfig; self.payload = payload
    }
}
