/// The header prepended to every video frame before fragmentation, `docs/video.md#the-frame-header`
/// (version 0 text).
public struct FrameHeader: Equatable, Sendable {
    public enum FrameType: UInt8, Sendable { case idr = 0, predicted = 1, audio = 2 }
    public enum RefKind: UInt8, Sendable { case none = 0, previous = 1, ltr = 2, ltrAny = 3 }

    public enum Flag {
        public static let ltrMark: UInt8 = 1 << 0
    }

    public enum Extension {
        public static let codecConfig: UInt8 = 1
    }

    public var frameType: FrameType
    public var refKind: RefKind
    public var flags: UInt8
    public var configGeneration: UInt32
    public var captureTimeMicros: UInt32
    public var refFrameID: UInt32?
    public var codecConfig: CodecConfig?

    public init(
        frameType: FrameType, refKind: RefKind, flags: UInt8 = 0, configGeneration: UInt32 = 0,
        captureTimeMicros: UInt32, refFrameID: UInt32? = nil, codecConfig: CodecConfig? = nil
    ) {
        self.frameType = frameType
        self.refKind = refKind
        self.flags = flags
        self.configGeneration = configGeneration
        self.captureTimeMicros = captureTimeMicros
        self.refFrameID = refFrameID
        self.codecConfig = codecConfig
    }

    public var encoded: Bytes {
        var w = ByteWriter(capacity: 128)
        w.u8(frameType.rawValue)
        w.u8(refKind.rawValue)
        w.u8(flags)
        w.u32(configGeneration)
        w.u32(captureTimeMicros)
        if refKind == .ltr { w.u32(refFrameID ?? 0) }
        var ext = ByteWriter()
        if let codecConfig { ext.tlv(Extension.codecConfig, codecConfig.encoded) }
        w.u16(UInt16(ext.count))
        w.append(ext.bytes)
        return w.bytes
    }

    /// Parses the header at the start of a reassembled frame; returns it and where the payload
    /// begins. Nil discards the frame: too short, an overrunning extension area, an unknown
    /// frame type or reference kind, or an IDR without `CODEC_CONFIG`.
    public static func parse(_ frame: Bytes) -> (header: FrameHeader, payloadOffset: Int)? {
        var r = ByteReader(frame)
        guard let type = try? r.u8(), let frameType = FrameType(rawValue: type),
            let kind = try? r.u8(), let refKind = RefKind(rawValue: kind),
            let flags = try? r.u8(), let generation = try? r.u32(), let capture = try? r.u32()
        else { return nil }
        var refFrameID: UInt32?
        if refKind == .ltr {
            guard let id = try? r.u32() else { return nil }
            refFrameID = id
        }
        guard let extLength = try? r.u16(), let ext = try? r.take(Int(extLength)) else { return nil }
        var codecConfig: CodecConfig?
        var e = ByteReader(ext)
        while !e.isAtEnd {
            guard let t = try? e.u8(), let length = try? e.u16(), let value = try? e.take(Int(length)) else {
                return nil
            }
            if t == Extension.codecConfig {
                guard let config = CodecConfig.parse(value) else { return nil }
                codecConfig = config
            }
        }
        if frameType == .idr, codecConfig == nil { return nil }
        let header = FrameHeader(
            frameType: frameType, refKind: refKind, flags: flags, configGeneration: generation,
            captureTimeMicros: capture, refFrameID: refFrameID, codecConfig: codecConfig)
        return (header, r.offset)
    }
}

/// HEVC parameter sets, each a NAL unit without a start code: `CODEC_CONFIG`, extension type 1.
public struct CodecConfig: Equatable, Sendable {
    public var vps: Bytes
    public var sps: Bytes
    public var pps: Bytes

    public init(vps: Bytes, sps: Bytes, pps: Bytes) {
        self.vps = vps
        self.sps = sps
        self.pps = pps
    }

    public var encoded: Bytes {
        var w = ByteWriter(capacity: vps.count + sps.count + pps.count + 12)
        for nal in [vps, sps, pps] {
            w.u32(UInt32(nal.count))
            w.append(nal)
        }
        return w.bytes
    }

    static func parse(_ value: ArraySlice<UInt8>) -> CodecConfig? {
        var r = ByteReader(value)
        var sets: [Bytes] = []
        for _ in 0..<3 {
            guard let length = try? r.u32(), let nal = try? r.take(Int(length)) else { return nil }
            sets.append(Bytes(nal))
        }
        return CodecConfig(vps: sets[0], sps: sets[1], pps: sets[2])
    }
}
