// Handshake packets. The first byte has its high bit set, which is how a receiver
// tells them from a protected packet before it has any keys.

/// Cleartext prefix of an INIT (0x80), client -> host. Authenticated as AAD over
/// the sealed body, so a tampered pairing id or ephemeral key fails to open.
///
/// `type:u8, version:u8, reserved:u16, pairing_id:u64, client_ephemeral[32]`
public struct InitPrefix: Equatable, Sendable {
    public static let size = 44
    public static let ephemeralSize = 32

    public var version: UInt8
    public var pairingID: UInt64
    public var clientEphemeral: [UInt8]

    public init(version: UInt8 = Wire.version, pairingID: UInt64, clientEphemeral: [UInt8]) {
        precondition(clientEphemeral.count == Self.ephemeralSize)
        self.version = version; self.pairingID = pairingID; self.clientEphemeral = clientEphemeral
    }

    public func encode(into w: inout ByteWriter) throws(WireError) {
        try w.put(HandshakeType.initPacket.rawValue)
        try w.put(version)
        try w.put(UInt16(0))
        try w.put(pairingID)
        try w.put(clientEphemeral)
    }

    /// Parses the prefix. Rejects the wrong version here, before any crypto, so
    /// the host can drop the packet silently and bump a counter.
    public static func decode(_ r: inout ByteReader) throws(WireError) -> InitPrefix {
        guard try r.u8() == HandshakeType.initPacket.rawValue else { throw .malformed }
        let version = try r.u8()
        guard version == Wire.version else { throw .unsupportedVersion(version) }
        try r.skip(2)
        let pairingID = try r.u64()
        let key = try r.byteArray(ephemeralSize)
        return InitPrefix(version: version, pairingID: pairingID, clientEphemeral: key)
    }
}

/// Cleartext prefix of a RESPONSE (0x81), host -> client.
///
/// `type:u8, version:u8, session_id:u32, host_ephemeral[32]`
public struct ResponsePrefix: Equatable, Sendable {
    public static let size = 38

    public var version: UInt8
    public var sessionID: UInt32
    public var hostEphemeral: [UInt8]

    public init(version: UInt8 = Wire.version, sessionID: UInt32, hostEphemeral: [UInt8]) {
        precondition(hostEphemeral.count == InitPrefix.ephemeralSize)
        self.version = version; self.sessionID = sessionID; self.hostEphemeral = hostEphemeral
    }

    public func encode(into w: inout ByteWriter) throws(WireError) {
        try w.put(HandshakeType.response.rawValue)
        try w.put(version)
        try w.put(sessionID)
        try w.put(hostEphemeral)
    }

    public static func decode(_ r: inout ByteReader) throws(WireError) -> ResponsePrefix {
        guard try r.u8() == HandshakeType.response.rawValue else { throw .malformed }
        let version = try r.u8()
        guard version == Wire.version else { throw .unsupportedVersion(version) }
        let sessionID = try r.u32()
        let key = try r.byteArray(InitPrefix.ephemeralSize)
        return ResponsePrefix(version: version, sessionID: sessionID, hostEphemeral: key)
    }
}

/// SESSION_UNKNOWN (0x82): `session_id:u32` plus a 16-byte HMAC of the host
/// secret and the session id. 21 bytes, always smaller than the 32-byte minimum
/// protected datagram that triggers it, so it cannot be used for amplification.
public struct SessionUnknown: Equatable, Sendable {
    public static let size = 21
    public static let tokenSize = 16

    public var sessionID: UInt32
    public var token: [UInt8]

    public init(sessionID: UInt32, token: [UInt8]) {
        precondition(token.count == Self.tokenSize)
        self.sessionID = sessionID; self.token = token
    }

    public func encode(into w: inout ByteWriter) throws(WireError) {
        try w.put(HandshakeType.sessionUnknown.rawValue)
        try w.put(sessionID)
        try w.put(token)
    }

    public static func decode(_ r: inout ByteReader) throws(WireError) -> SessionUnknown {
        guard try r.u8() == HandshakeType.sessionUnknown.rawValue else { throw .malformed }
        let sessionID = try r.u32()
        let token = try r.byteArray(tokenSize)
        return SessionUnknown(sessionID: sessionID, token: token)
    }
}

// MARK: - Sealed bodies

/// The AEAD-sealed TLV body of an INIT.
public struct InitBody: Equatable, Sendable {
    public var capabilities: Capabilities = [.ltr]
    public var streams: [StreamDescriptor] = []
    public var maxDatagramSize: UInt16 = UInt16(Wire.defaultMaxDatagramSize)
    /// The client's monotonic microseconds, echoed nowhere: it exists so the host
    /// can reject a replayed INIT that arrives long after it was made.
    public var clientTimestamp: UInt64 = 0
    /// Set when the client is re-handshaking and hopes the host still has this
    /// session parked under the same pairing, to be adopted with new keys.
    public var resumeSessionID: UInt32?
    public var config = SessionConfig()

    public init() {}

    public func encode(into w: inout ByteWriter) throws(WireError) {
        try TLV.put(&w, TLVType.capabilities.rawValue, u32: capabilities.rawValue)
        try w.put(TLVType.streamTable.rawValue)
        try w.put(UInt16(streams.count * 4))
        for s in streams {
            try w.put(s.id); try w.put(s.kind.rawValue)
            try w.put(s.direction.rawValue); try w.put(s.streamClass.rawValue)
        }
        try TLV.put(&w, TLVType.maxDatagramSize.rawValue, u16: maxDatagramSize)
        try TLV.put(&w, TLVType.clientTimestamp.rawValue, u64: clientTimestamp)
        if let sid = resumeSessionID { try TLV.put(&w, TLVType.resumeSessionID.rawValue, u32: sid) }
        var cfg = ControlBody.state(config: config, flags: [])
        cfg.maxDatagramSize = nil     // carried on its own above
        try w.put(TLVType.bitrate.rawValue)
        let site = try w.reserve(2)
        let start = w.written
        try cfg.encode(into: &w)
        w.patch(UInt16(w.written - start), at: site)
    }

    public static func decode(_ r: inout ByteReader) throws(WireError) -> InitBody {
        var body = InitBody()
        while r.remaining >= 3 {
            let type = try r.u8()
            // Type 0 is reserved and never written, so it marks the end of the
            // TLVs: the INIT's authenticated padding reads as one zero byte.
            if type == 0 { break }
            let len = Int(try r.u16())
            guard r.remaining >= len else { throw .truncated }
            switch TLVType(rawValue: type) {
            case .capabilities where len == 4:
                body.capabilities = Capabilities(rawValue: try r.u32())
            case .streamTable:
                guard len % 4 == 0 else { throw .malformed }
                var table = ByteReader(try r.take(len))
                while table.remaining >= 4 {
                    let id = try table.u8()
                    guard let kind = StreamKind(rawValue: try table.u8()),
                          let dir = StreamDirection(rawValue: try table.u8()),
                          let cls = StreamClass(rawValue: try table.u8()) else { continue }
                    body.streams.append(StreamDescriptor(id: id, kind: kind, direction: dir, streamClass: cls))
                }
            case .maxDatagramSize where len == 2: body.maxDatagramSize = try r.u16()
            case .clientTimestamp where len == 8: body.clientTimestamp = try r.u64()
            case .resumeSessionID where len == 4: body.resumeSessionID = try r.u32()
            case .bitrate:
                var nested = ByteReader(try r.take(len))
                let cfg = try ControlBody.decode(&nested)
                _ = cfg.apply(to: &body.config)
                body.config.generation = cfg.generation ?? 0
            default: try r.skip(len)   // must-ignore
            }
        }
        body.config.maxDatagramSize = body.maxDatagramSize
        return body
    }
}

/// The AEAD-sealed TLV body of a RESPONSE.
public struct ResponseBody: Equatable, Sendable {
    /// `INTRA_REFRESH` is reserved and never accepted in v0; `FEC` is [NONE].
    public var acceptedCapabilities: Capabilities = []
    public var streams: [StreamDescriptor] = []
    public var maxDatagramSize: UInt16 = UInt16(Wire.defaultMaxDatagramSize)
    public var pipelineIdleAfterMillis: UInt32 = 60_000
    public var graceWindowMillis: UInt32 = 30 * 60 * 1000
    public var resetToken: [UInt8] = [UInt8](repeating: 0, count: SessionUnknown.tokenSize)
    public var config = SessionConfig()
    /// True when the host adopted a parked session the client named.
    public var adoptedResume = false

    public init() {}

    public func encode(into w: inout ByteWriter) throws(WireError) {
        try TLV.put(&w, TLVType.capabilities.rawValue, u32: acceptedCapabilities.rawValue)
        try w.put(TLVType.streamTable.rawValue)
        try w.put(UInt16(streams.count * 4))
        for s in streams {
            try w.put(s.id); try w.put(s.kind.rawValue)
            try w.put(s.direction.rawValue); try w.put(s.streamClass.rawValue)
        }
        try TLV.put(&w, TLVType.maxDatagramSize.rawValue, u16: maxDatagramSize)
        try TLV.put(&w, TLVType.pipelineIdleAfter.rawValue, u32: pipelineIdleAfterMillis)
        try TLV.put(&w, TLVType.graceWindow.rawValue, u32: graceWindowMillis)
        try w.put(TLVType.resetToken.rawValue)
        try w.put(UInt16(resetToken.count))
        try w.put(resetToken)
        try TLV.put(&w, TLVType.fecSchemes.rawValue, u8: 0)   // [NONE]
        try TLV.put(&w, TLVType.stateFlags.rawValue, u8: adoptedResume ? StateFlags.resume.rawValue : 0)
        try w.put(TLVType.bitrate.rawValue)
        let site = try w.reserve(2)
        let start = w.written
        var cfg = ControlBody.state(config: config, flags: [])
        cfg.maxDatagramSize = nil
        try cfg.encode(into: &w)
        w.patch(UInt16(w.written - start), at: site)
    }

    public static func decode(_ r: inout ByteReader) throws(WireError) -> ResponseBody {
        var body = ResponseBody()
        while r.remaining >= 3 {
            let type = try r.u8()
            // Type 0 is reserved and never written, so it marks the end of the
            // TLVs: the INIT's authenticated padding reads as one zero byte.
            if type == 0 { break }
            let len = Int(try r.u16())
            guard r.remaining >= len else { throw .truncated }
            switch TLVType(rawValue: type) {
            case .capabilities where len == 4:
                body.acceptedCapabilities = Capabilities(rawValue: try r.u32())
            case .streamTable:
                guard len % 4 == 0 else { throw .malformed }
                var table = ByteReader(try r.take(len))
                while table.remaining >= 4 {
                    let id = try table.u8()
                    guard let kind = StreamKind(rawValue: try table.u8()),
                          let dir = StreamDirection(rawValue: try table.u8()),
                          let cls = StreamClass(rawValue: try table.u8()) else { continue }
                    body.streams.append(StreamDescriptor(id: id, kind: kind, direction: dir, streamClass: cls))
                }
            case .maxDatagramSize where len == 2: body.maxDatagramSize = try r.u16()
            case .pipelineIdleAfter where len == 4: body.pipelineIdleAfterMillis = try r.u32()
            case .graceWindow where len == 4: body.graceWindowMillis = try r.u32()
            case .resetToken where len == SessionUnknown.tokenSize:
                body.resetToken = try r.byteArray(len)
            case .stateFlags where len == 1:
                body.adoptedResume = StateFlags(rawValue: try r.u8()).contains(.resume)
            case .bitrate:
                var nested = ByteReader(try r.take(len))
                let cfg = try ControlBody.decode(&nested)
                _ = cfg.apply(to: &body.config)
                body.config.generation = cfg.generation ?? 0
            default: try r.skip(len)
            }
        }
        body.config.maxDatagramSize = body.maxDatagramSize
        return body
    }
}
