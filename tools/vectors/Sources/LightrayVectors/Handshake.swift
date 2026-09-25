/// The version 1 handshake packets, as `docs/handshake.md` defines them.
public enum Handshake {
    public static let version: UInt8 = 1
    public static let prologueLabel = Bytes("lightray-v1".utf8)
    public static let resetTokenLabel = Bytes("lightray-v1 reset".utf8)

    /// The first byte of a handshake datagram.
    public enum DatagramType {
        public static let initiation: UInt8 = 0x80
        public static let response: UInt8 = 0x81
        public static let sessionUnknown: UInt8 = 0x82
    }

    /// Handshake parameter TLV types.
    public enum Param {
        public static let settings: UInt8 = 1
        public static let timestamp: UInt8 = 2
        public static let capabilities: UInt8 = 3
        public static let streamTable: UInt8 = 4
        public static let maxDatagramSize: UInt8 = 5
        public static let resumeSessionID: UInt8 = 6
        public static let lifecycle: UInt8 = 7
    }

    public static let initHeaderLength = 12
    /// Header, ephemeral and tag: everything in an INIT except its payload.
    public static let initOverhead = initHeaderLength + Noise.dhLength + Noise.tagLength

    public static func initHeader(pairingID: UInt64) -> Bytes {
        [DatagramType.initiation, version, 0, 0] + be64(pairingID)
    }

    /// `"lightray-v1" ‖ INIT[0..12)`.
    public static func prologue(initHeader: Bytes) -> Bytes {
        precondition(initHeader.count == initHeaderLength)
        return prologueLabel + initHeader
    }

    /// `params_len:u16 ‖ params ‖ zero padding`, sized so the INIT is exactly the datagram size.
    public static func initPayload(params: Bytes, maxDatagramSize: Int) -> Bytes {
        let length = maxDatagramSize - initOverhead
        precondition(2 + params.count <= length)
        return be16(UInt16(params.count)) + params + Bytes(repeating: 0, count: length - 2 - params.count)
    }

    public static func buildInit(
        psk: Bytes, pairingID: UInt64, ephemeralPrivate: Bytes, params: Bytes, maxDatagramSize: Int
    ) -> (datagram: Bytes, initiator: NNpsk0) {
        let header = initHeader(pairingID: pairingID)
        var initiator = NNpsk0(
            role: .initiator, prologue: prologue(initHeader: header), psk: psk,
            ephemeralPrivate: ephemeralPrivate)
        let message = initiator.writeMessageA(payload: initPayload(params: params, maxDatagramSize: maxDatagramSize))
        let datagram = header + message
        precondition(datagram.count == maxDatagramSize)
        return (datagram, initiator)
    }

    /// What a host does with an INIT once it has found the pairing's PSK: returns the payload
    /// and the responder state that will write the RESPONSE.
    public static func readInit(_ datagram: Bytes, psk: Bytes, ephemeralPrivate: Bytes)
        -> (payload: Bytes, responder: NNpsk0)?
    {
        guard datagram.count >= initOverhead, datagram[0] == DatagramType.initiation,
            datagram[1] == version
        else { return nil }
        let header = Array(datagram[0..<initHeaderLength])
        var responder = NNpsk0(
            role: .responder, prologue: prologue(initHeader: header), psk: psk,
            ephemeralPrivate: ephemeralPrivate)
        guard let payload = responder.readMessageA(Array(datagram[initHeaderLength...])) else { return nil }
        return (payload, responder)
    }

    /// `session_id:u32 ‖ reset_token[16] ‖ TLVs`.
    public static func responsePayload(sessionID: UInt32, resetToken: Bytes, params: Bytes) -> Bytes {
        precondition(resetToken.count == 16)
        return be32(sessionID) + resetToken + params
    }

    public static func buildResponse(responder: inout NNpsk0, payload: Bytes) -> Bytes {
        [DatagramType.response, version] + responder.writeMessageB(payload: payload)
    }

    public static func readResponse(_ datagram: Bytes, initiator: inout NNpsk0) -> Bytes? {
        guard datagram.count >= 2 + Noise.dhLength + Noise.tagLength,
            datagram[0] == DatagramType.response, datagram[1] == version
        else { return nil }
        return initiator.readMessageB(Array(datagram[2...]))
    }

    public static func resetToken(hostSecret: Bytes, sessionID: UInt32) -> Bytes {
        Array(Noise.hmac(key: hostSecret, resetTokenLabel + be32(sessionID)).prefix(16))
    }

    public static func sessionUnknown(sessionID: UInt32, token: Bytes) -> Bytes {
        precondition(token.count == 16)
        return [DatagramType.sessionUnknown, version] + be32(sessionID) + token
    }
}

/// `type:u8, length:u16, value`: the encoding of every TLV and every chunk.
public func tlv(_ type: UInt8, _ value: Bytes) -> Bytes {
    precondition(value.count <= Int(UInt16.max))
    return [type] + be16(UInt16(value.count)) + value
}

/// A stream table entry: `id:u8, kind:u8, direction:u8, class:u8`.
public struct StreamEntry: Sendable {
    public enum Kind {
        public static let video: UInt8 = 1
        public static let audio: UInt8 = 2
        public static let input: UInt8 = 3
        public static let mic: UInt8 = 4
    }

    public enum Direction {
        public static let hostToClient: UInt8 = 1
        public static let clientToHost: UInt8 = 2
        public static let bidirectional: UInt8 = 3
    }

    public enum Class {
        public static let media: UInt8 = 0
        public static let realtime: UInt8 = 1
        public static let reliable: UInt8 = 2
        public static let unreliable: UInt8 = 3
    }

    public let id: UInt8
    public let kind: UInt8
    public let direction: UInt8
    public let streamClass: UInt8

    public init(id: UInt8, kind: UInt8, direction: UInt8, streamClass: UInt8) {
        self.id = id
        self.kind = kind
        self.direction = direction
        self.streamClass = streamClass
    }

    public var bytes: Bytes { [id, kind, direction, streamClass] }
}
