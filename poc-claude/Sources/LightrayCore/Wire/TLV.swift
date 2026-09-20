// TLV codec for handshake bodies and control messages: `type:u8, len:u16, value`.
// Unknown types are skipped (must-ignore), which is what lets a later version add
// fields without breaking a v0 peer.

public enum TLV {
    @inlinable
    public static func put(_ w: inout ByteWriter, _ type: UInt8, u8 v: UInt8) throws(WireError) {
        try w.put(type); try w.put(UInt16(1)); try w.put(v)
    }

    @inlinable
    public static func put(_ w: inout ByteWriter, _ type: UInt8, u16 v: UInt16) throws(WireError) {
        try w.put(type); try w.put(UInt16(2)); try w.put(v)
    }

    @inlinable
    public static func put(_ w: inout ByteWriter, _ type: UInt8, u32 v: UInt32) throws(WireError) {
        try w.put(type); try w.put(UInt16(4)); try w.put(v)
    }

    @inlinable
    public static func put(_ w: inout ByteWriter, _ type: UInt8, u64 v: UInt64) throws(WireError) {
        try w.put(type); try w.put(UInt16(8)); try w.put(v)
    }

    @inlinable
    public static func put(_ w: inout ByteWriter, _ type: UInt8, bytes: UnsafeRawBufferPointer) throws(WireError) {
        try w.put(type); try w.put(UInt16(bytes.count)); try w.put(bytes: bytes)
    }
}

/// Control-message and handshake TLV types.
public enum TLVType: UInt8, Sendable {
    // Handshake
    case capabilities = 0x01
    case streamTable = 0x02
    case maxDatagramSize = 0x03
    case clientTimestamp = 0x04
    case resumeSessionID = 0x05
    case pipelineIdleAfter = 0x06
    case graceWindow = 0x07
    case resetToken = 0x08
    case fecSchemes = 0x09
    // RECONFIGURE / STATE
    case bitrate = 0x20
    case bitrateFloor = 0x21
    case resolution = 0x22
    case framerate = 0x23
    case hdr = 0x24
    case configGeneration = 0x25
    case stateFlags = 0x26
    case rejectedMask = 0x27
}

/// Control messages on reliable stream 0. One path for every parameter: manual
/// bitrate changes ride RECONFIGURE too. There is no codec TLV, because the
/// codec is fixed by the wire version.
public enum ControlMessage: UInt8, Sendable {
    case reconfigure = 0x01
    case reconfigureResult = 0x02
    case state = 0x03
}

public struct StateFlags: OptionSet, Sendable {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let resume = StateFlags(rawValue: 1 << 0)
    public static let backstop = StateFlags(rawValue: 1 << 1)
}

/// The parameters RECONFIGURE can change and STATE snapshots.
public struct SessionConfig: Equatable, Sendable {
    public var bitrate: UInt32 = 20_000_000
    public var bitrateFloor: UInt32 = 2_000_000
    public var width: UInt16 = 1920
    public var height: UInt16 = 1080
    public var framerate: UInt16 = 60
    public var hdr: Bool = false
    public var maxDatagramSize: UInt16 = UInt16(Wire.defaultMaxDatagramSize)
    public var generation: UInt16 = 0

    public init() {}

    /// One frame interval at the configured frame rate.
    @inlinable public var frameInterval: Interval {
        Interval(nanos: framerate == 0 ? 16_666_667 : 1_000_000_000 / UInt64(framerate))
    }
}

/// A parsed control message. Only the fields present in the TLVs are set.
public struct ControlBody: Equatable, Sendable {
    public var message: ControlMessage
    public var reqID: UInt32 = 0
    public var scopeStream: UInt8 = 0
    public var bitrate: UInt32?
    public var bitrateFloor: UInt32?
    public var resolution: (UInt16, UInt16)?
    public var framerate: UInt16?
    public var hdr: Bool?
    public var maxDatagramSize: UInt16?
    public var generation: UInt16?
    public var stateFlags: StateFlags = []
    public var rejectedMask: UInt32 = 0

    public init(message: ControlMessage, reqID: UInt32 = 0, scopeStream: UInt8 = 0) {
        self.message = message; self.reqID = reqID; self.scopeStream = scopeStream
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.message == b.message && a.reqID == b.reqID && a.scopeStream == b.scopeStream
            && a.bitrate == b.bitrate && a.bitrateFloor == b.bitrateFloor
            && a.resolution?.0 == b.resolution?.0 && a.resolution?.1 == b.resolution?.1
            && a.framerate == b.framerate && a.hdr == b.hdr
            && a.maxDatagramSize == b.maxDatagramSize && a.generation == b.generation
            && a.stateFlags == b.stateFlags && a.rejectedMask == b.rejectedMask
    }

    /// `msg_type:u8, req_id:u32, scope_stream:u8`, then TLVs.
    public func encode(into w: inout ByteWriter) throws(WireError) {
        try w.put(message.rawValue)
        try w.put(reqID)
        try w.put(scopeStream)
        if let v = bitrate { try TLV.put(&w, TLVType.bitrate.rawValue, u32: v) }
        if let v = bitrateFloor { try TLV.put(&w, TLVType.bitrateFloor.rawValue, u32: v) }
        if let v = resolution {
            try w.put(TLVType.resolution.rawValue); try w.put(UInt16(4))
            try w.put(v.0); try w.put(v.1)
        }
        if let v = framerate { try TLV.put(&w, TLVType.framerate.rawValue, u16: v) }
        if let v = hdr { try TLV.put(&w, TLVType.hdr.rawValue, u8: v ? 1 : 0) }
        if let v = maxDatagramSize { try TLV.put(&w, TLVType.maxDatagramSize.rawValue, u16: v) }
        if let v = generation { try TLV.put(&w, TLVType.configGeneration.rawValue, u16: v) }
        if !stateFlags.isEmpty { try TLV.put(&w, TLVType.stateFlags.rawValue, u8: stateFlags.rawValue) }
        if rejectedMask != 0 { try TLV.put(&w, TLVType.rejectedMask.rawValue, u32: rejectedMask) }
    }

    public static func decode(_ r: inout ByteReader) throws(WireError) -> ControlBody {
        guard let message = ControlMessage(rawValue: try r.u8()) else { throw .malformed }
        var body = ControlBody(message: message, reqID: try r.u32(), scopeStream: try r.u8())
        while r.remaining >= 3 {
            let type = try r.u8()
            // Type 0 is reserved and never written, so it marks the end of the
            // TLVs: the INIT's authenticated padding reads as one zero byte.
            if type == 0 { break }
            let len = Int(try r.u16())
            guard r.remaining >= len else { throw .truncated }
            switch TLVType(rawValue: type) {
            case .bitrate where len == 4: body.bitrate = try r.u32()
            case .bitrateFloor where len == 4: body.bitrateFloor = try r.u32()
            case .resolution where len == 4: body.resolution = (try r.u16(), try r.u16())
            case .framerate where len == 2: body.framerate = try r.u16()
            case .hdr where len == 1: body.hdr = try r.u8() != 0
            case .maxDatagramSize where len == 2: body.maxDatagramSize = try r.u16()
            case .configGeneration where len == 2: body.generation = try r.u16()
            case .stateFlags where len == 1: body.stateFlags = StateFlags(rawValue: try r.u8())
            case .rejectedMask where len == 4: body.rejectedMask = try r.u32()
            default: try r.skip(len)   // must-ignore
            }
        }
        return body
    }

    /// A STATE snapshot of `config`.
    public static func state(config: SessionConfig, flags: StateFlags, reqID: UInt32 = 0) -> ControlBody {
        var b = ControlBody(message: .state, reqID: reqID)
        b.bitrate = config.bitrate
        b.bitrateFloor = config.bitrateFloor
        b.resolution = (config.width, config.height)
        b.framerate = config.framerate
        b.hdr = config.hdr
        b.maxDatagramSize = config.maxDatagramSize
        b.generation = config.generation
        b.stateFlags = flags
        return b
    }

    /// Applies the present fields to `config`, bumping the generation when
    /// anything actually changed. Returns the fields that were rejected.
    public func apply(to config: inout SessionConfig) -> UInt32 {
        var rejected: UInt32 = 0
        var changed = false
        if let v = bitrate {
            if v >= 100_000, v <= 500_000_000 { if config.bitrate != v { config.bitrate = v; changed = true } }
            else { rejected |= 1 << UInt32(TLVType.bitrate.rawValue & 0x1f) }
        }
        if let v = bitrateFloor {
            if v >= 100_000, v <= config.bitrate { if config.bitrateFloor != v { config.bitrateFloor = v; changed = true } }
            else { rejected |= 1 << UInt32(TLVType.bitrateFloor.rawValue & 0x1f) }
        }
        if let v = resolution {
            if v.0 >= 16, v.1 >= 16 {
                if config.width != v.0 || config.height != v.1 { config.width = v.0; config.height = v.1; changed = true }
            } else { rejected |= 1 << UInt32(TLVType.resolution.rawValue & 0x1f) }
        }
        if let v = framerate {
            if v >= 1, v <= 240 { if config.framerate != v { config.framerate = v; changed = true } }
            else { rejected |= 1 << UInt32(TLVType.framerate.rawValue & 0x1f) }
        }
        if let v = hdr, config.hdr != v { config.hdr = v; changed = true }
        if let v = maxDatagramSize {
            if v >= UInt16(Wire.minMaxDatagramSize), v <= UInt16(Wire.maxMaxDatagramSize) {
                if config.maxDatagramSize != v { config.maxDatagramSize = v; changed = true }
            } else { rejected |= 1 << UInt32(TLVType.maxDatagramSize.rawValue & 0x1f) }
        }
        if changed { config.generation &+= 1 }
        return rejected
    }
}
