import CryptoKit

/// The handshake packets of `docs/handshake.md`.
public enum Handshake {
    public static let version: UInt8 = 1
    static let prologueLabel = Bytes("lightray-v1".utf8)
    static let resetTokenLabel = Bytes("lightray-v1 reset".utf8)

    public enum PacketType {
        public static let initiation: UInt8 = 0x80
        public static let response: UInt8 = 0x81
        public static let sessionUnknown: UInt8 = 0x82
    }

    public static let initHeaderLength = 12
    /// Header, ephemeral and tag: all of an INIT but its payload.
    public static let initOverhead = initHeaderLength + Noise.dhLength + Noise.tagLength
    public static let sessionUnknownLength = 22
    public static let datagramSizeRange = 256...9000

    static func initHeader(pairingID: UInt64) -> Bytes {
        var w = ByteWriter(capacity: 12)
        w.u8(PacketType.initiation)
        w.u8(version)
        w.u16(0)
        w.u64(pairingID)
        return w.bytes
    }

    /// `HMAC-SHA256(host_secret, "lightray-v1 reset" ‖ session_id)[0..16)`.
    public static func resetToken(hostSecret: Bytes, sessionID: UInt32) -> Bytes {
        var w = ByteWriter()
        w.append(resetTokenLabel)
        w.u32(sessionID)
        return Array(Noise.hmac(key: hostSecret, w.bytes).prefix(16))
    }

    public static func sessionUnknown(sessionID: UInt32, token: Bytes) -> Bytes {
        var w = ByteWriter(capacity: sessionUnknownLength)
        w.u8(PacketType.sessionUnknown)
        w.u8(version)
        w.u32(sessionID)
        w.append(token)
        return w.bytes
    }
}

// MARK: - Streams

/// A stream table entry, `docs/handshake.md#stream_table-4`.
public struct StreamEntry: Hashable, Sendable {
    public enum Kind: UInt8, Sendable { case video = 1, audio = 2, input = 3, mic = 4, data = 6 }
    public enum Direction: UInt8, Sendable { case hostToClient = 1, clientToHost = 2, bidirectional = 3 }
    public enum Class: UInt8, Sendable { case media = 0, realtime = 1, reliable = 2, unreliable = 3 }

    public var id: UInt8
    public var kind: Kind
    public var direction: Direction
    public var streamClass: Class

    public init(id: UInt8, kind: Kind, direction: Direction, streamClass: Class) {
        self.id = id
        self.kind = kind
        self.direction = direction
        self.streamClass = streamClass
    }

    /// Stream 0: never listed, always present, bidirectional and reliable.
    public static let control = StreamEntry(id: 0, kind: .data, direction: .bidirectional, streamClass: .reliable)
}

public struct StreamTable: Equatable, Sendable {
    public private(set) var entries: [StreamEntry]

    public init(_ entries: [StreamEntry]) { self.entries = entries }

    /// Stream 0 is found here even though it is never listed.
    public func entry(_ id: UInt8) -> StreamEntry? {
        id == 0 ? .control : entries.first { $0.id == id }
    }

    public func first(kind: StreamEntry.Kind, direction: StreamEntry.Direction) -> StreamEntry? {
        entries.first { $0.kind == kind && $0.direction == direction }
    }

    var encoded: Bytes { entries.flatMap { [$0.id, $0.kind.rawValue, $0.direction.rawValue, $0.streamClass.rawValue] } }

    static func decode(_ value: ArraySlice<UInt8>) throws(HandshakeError) -> StreamTable {
        guard value.count % 4 == 0 else { throw .invalidParameters("stream table length") }
        var entries: [StreamEntry] = []
        var ids = Set<UInt8>()
        var i = value.startIndex
        while i < value.endIndex {
            let id = value[i]
            guard id != 0, ids.insert(id).inserted,
                let kind = StreamEntry.Kind(rawValue: value[i + 1]),
                let direction = StreamEntry.Direction(rawValue: value[i + 2]),
                let streamClass = StreamEntry.Class(rawValue: value[i + 3])
            else { throw .invalidParameters("stream table entry") }
            entries.append(StreamEntry(id: id, kind: kind, direction: direction, streamClass: streamClass))
            i += 4
        }
        guard !entries.isEmpty, entries.count <= 32 else { throw .invalidParameters("stream table size") }
        return StreamTable(entries)
    }
}

// MARK: - Parameters

public enum HandshakeError: Error, Equatable {
    /// The packet is dropped without reply and without changing anything.
    case discard(String)
    /// The handshake is rejected: a host discards the INIT, a client abandons the handshake.
    case invalidParameters(String)
}

/// `CAPABILITIES` bits, `docs/registries.md` version 0 text. FEC is provisional here: version 0
/// reserves the bit, and version 1 will define it (`macos/README.md`).
public enum Capability {
    public static let ltr: UInt8 = 1 << 0
    public static let fec: UInt8 = 1 << 2
}

/// The parameter TLVs of INIT and RESPONSE. Types this version does not define yet
/// (`SETTINGS`, `LIFECYCLE`) are checked for duplicates and otherwise skipped.
public struct HandshakeParams: Equatable, Sendable {
    public enum TLV {
        public static let settings: UInt8 = 1
        public static let timestamp: UInt8 = 2
        public static let capabilities: UInt8 = 3
        public static let streamTable: UInt8 = 4
        public static let maxDatagramSize: UInt8 = 5
        public static let resumeSessionID: UInt8 = 6
        public static let lifecycle: UInt8 = 7
    }

    public var timestamp: UInt64?
    /// In an INIT, what the client offers; in a RESPONSE, what the host accepted of it.
    public var capabilities: UInt8?
    public var streamTable: StreamTable?
    public var maxDatagramSize: UInt16?
    public var resumeSessionID: UInt32?

    public init(
        timestamp: UInt64? = nil, capabilities: UInt8? = nil, streamTable: StreamTable? = nil,
        maxDatagramSize: UInt16? = nil, resumeSessionID: UInt32? = nil
    ) {
        self.timestamp = timestamp
        self.capabilities = capabilities
        self.streamTable = streamTable
        self.maxDatagramSize = maxDatagramSize
        self.resumeSessionID = resumeSessionID
    }

    /// In ascending type order.
    public var encoded: Bytes {
        var w = ByteWriter()
        if let timestamp {
            var v = ByteWriter()
            v.u64(timestamp)
            w.tlv(TLV.timestamp, v.bytes)
        }
        if let capabilities { w.tlv(TLV.capabilities, [capabilities]) }
        if let streamTable { w.tlv(TLV.streamTable, streamTable.encoded) }
        if let maxDatagramSize { w.tlv(TLV.maxDatagramSize, [UInt8(maxDatagramSize >> 8), UInt8(maxDatagramSize & 0xff)]) }
        if let resumeSessionID {
            var v = ByteWriter()
            v.u32(resumeSessionID)
            w.tlv(TLV.resumeSessionID, v.bytes)
        }
        return w.bytes
    }

    public static func decode(_ params: ArraySlice<UInt8>) throws(HandshakeError) -> HandshakeParams {
        var result = HandshakeParams()
        var seen = Set<UInt8>()
        var r = ByteReader(params)
        while !r.isAtEnd {
            guard r.remaining >= 3 else { throw .invalidParameters("trailing bytes") }
            let type = try! r.u8()
            let length = Int(try! r.u16())
            guard let value = try? r.take(length) else { throw .invalidParameters("TLV overruns") }
            if (1...7).contains(type), !seen.insert(type).inserted { throw .invalidParameters("duplicate TLV \(type)") }
            var v = ByteReader(value)
            switch type {
            case TLV.timestamp:
                guard length == 8 else { throw .invalidParameters("TIMESTAMP length") }
                result.timestamp = try! v.u64()
            case TLV.capabilities:
                guard length == 1 else { throw .invalidParameters("CAPABILITIES length") }
                result.capabilities = try! v.u8()
            case TLV.streamTable:
                result.streamTable = try StreamTable.decode(value)
            case TLV.maxDatagramSize:
                guard length == 2 else { throw .invalidParameters("MAX_DATAGRAM_SIZE length") }
                let size = try! v.u16()
                guard Handshake.datagramSizeRange.contains(Int(size)) else {
                    throw .invalidParameters("MAX_DATAGRAM_SIZE range")
                }
                result.maxDatagramSize = size
            case TLV.resumeSessionID:
                guard length == 4 else { throw .invalidParameters("RESUME_SESSION_ID length") }
                result.resumeSessionID = try! v.u32()
            default:
                break
            }
        }
        return result
    }
}

// MARK: - The client's side

/// A client's outstanding handshake: the INIT it sends, byte for byte on every retransmission,
/// and the state it opens each RESPONSE against.
public struct ClientHandshake {
    public let datagram: Bytes
    public let params: HandshakeParams
    private let state: NNpsk0

    public struct Result: Sendable {
        public let sessionID: UInt32
        public let resetToken: Bytes
        public let params: HandshakeParams
        public let sendKey: Bytes
        public let receiveKey: Bytes
        public let handshakeHash: Bytes
    }

    /// `params` must carry `TIMESTAMP`, `STREAM_TABLE` and `MAX_DATAGRAM_SIZE`; the INIT is padded
    /// to that size.
    public init(
        psk: Bytes, pairingID: UInt64, params: HandshakeParams,
        ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()
    ) {
        let size = Int(params.maxDatagramSize!)
        precondition(Handshake.datagramSizeRange.contains(size))
        let header = Handshake.initHeader(pairingID: pairingID)
        var state = NNpsk0(prologue: Handshake.prologueLabel + header, psk: psk, ephemeral: ephemeral)
        let encoded = params.encoded
        let payloadLength = size - Handshake.initOverhead
        precondition(2 + encoded.count <= payloadLength)
        var payload = ByteWriter(capacity: payloadLength)
        payload.u16(UInt16(encoded.count))
        payload.append(encoded)
        payload.append(Bytes(repeating: 0, count: payloadLength - payload.count))
        datagram = header + state.writeMessageA(payload: payload.bytes)
        self.params = params
        self.state = state
    }

    /// Opens a candidate RESPONSE on a copy of the INIT's state. Nil means discard it and keep
    /// waiting; a thrown error means the handshake must be abandoned.
    public func open(_ response: Bytes) throws(HandshakeError) -> Result? {
        guard response.count <= datagram.count,
            response.count >= 2 + Noise.dhLength + Noise.tagLength,
            response[0] == Handshake.PacketType.response, response[1] == Handshake.version
        else { return nil }
        var copy = state
        guard let payload = copy.readMessageB(response[2...]) else { return nil }
        guard payload.count >= 20 else { throw .invalidParameters("RESPONSE payload too short") }
        var r = ByteReader(payload)
        let sessionID = try! r.u32()
        guard sessionID != 0 else { throw .invalidParameters("session id 0") }
        let token = Bytes(try! r.take(16))
        let accepted = try HandshakeParams.decode(r.rest())
        guard let table = accepted.streamTable, let size = accepted.maxDatagramSize else {
            throw .invalidParameters("RESPONSE missing a required TLV")
        }
        guard accepted.timestamp == nil, accepted.resumeSessionID == nil else {
            throw .invalidParameters("RESPONSE carries a TLV it must not")
        }
        guard size <= params.maxDatagramSize! else { throw .invalidParameters("RESPONSE raises the datagram size") }
        guard (accepted.capabilities ?? 0) & ~(params.capabilities ?? 0) == 0 else {
            throw .invalidParameters("RESPONSE accepts a capability not offered")
        }
        let proposed = params.streamTable!.entries
        guard table.entries.allSatisfy({ proposed.contains($0) }) else {
            throw .invalidParameters("RESPONSE adds or changes a stream")
        }
        let (c2h, h2c) = copy.symmetric.split()
        return Result(
            sessionID: sessionID, resetToken: token, params: accepted, sendKey: c2h, receiveKey: h2c,
            handshakeHash: copy.handshakeHash)
    }
}

// MARK: - The host's side

/// An INIT the host has opened, waiting for the host to decide what to answer.
public struct OpenedInit {
    public let pairingID: UInt64
    public let params: HandshakeParams
    public let datagram: Bytes
    fileprivate var state: NNpsk0
    fileprivate let remoteEphemeral: Bytes

    public struct Accepted: Sendable {
        public let response: Bytes
        public let sendKey: Bytes
        public let receiveKey: Bytes
        public let handshakeHash: Bytes
    }

    /// Opens an INIT. Checks, in the order `docs/handshake.md` requires: the size range, the type
    /// and version, the pairing, the seal. Parameters are parsed but not judged; the caller first
    /// consults its INIT cache, then calls `validate`.
    public static func open(_ datagram: Bytes, psk: (UInt64) -> Bytes?) throws(HandshakeError) -> OpenedInit {
        guard Handshake.datagramSizeRange.contains(datagram.count) else { throw .discard("INIT size") }
        guard datagram[0] == Handshake.PacketType.initiation else { throw .discard("not an INIT") }
        guard datagram[1] == Handshake.version else { throw .discard("version") }
        var r = ByteReader(datagram)
        _ = try! r.take(4)
        let pairingID = try! r.u64()
        guard let key = psk(pairingID) else { throw .discard("unknown pairing") }
        var state = NNpsk0(
            prologue: Handshake.prologueLabel + datagram[0..<Handshake.initHeaderLength], psk: key,
            ephemeral: .init())
        guard let (payload, remote) = state.readMessageA(datagram[Handshake.initHeaderLength...]) else {
            throw .discard("INIT fails to open")
        }
        var p = ByteReader(payload)
        let paramsLength = Int(try! p.u16())
        guard let params = try? p.take(paramsLength) else { throw .discard("params_len exceeds payload") }
        return OpenedInit(
            pairingID: pairingID, params: try HandshakeParams.decode(params), datagram: datagram, state: state,
            remoteEphemeral: remote)
    }

    /// The checks that follow the cache lookup.
    public func validate(unixTime: UInt64) throws(HandshakeError) {
        guard let size = params.maxDatagramSize, params.streamTable != nil, let timestamp = params.timestamp else {
            throw .invalidParameters("INIT missing a required TLV")
        }
        guard Int(size) == datagram.count else { throw .discard("INIT length differs from its MAX_DATAGRAM_SIZE") }
        let skew = timestamp > unixTime ? timestamp - unixTime : unixTime - timestamp
        guard skew <= 30 else { throw .discard("INIT timestamp outside the window") }
    }

    /// Writes the RESPONSE. Nil if the client's ephemeral is a low-order point.
    public func respond(
        sessionID: UInt32, resetToken: Bytes, params accepted: HandshakeParams,
        ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()
    ) -> Accepted? {
        precondition(sessionID != 0 && resetToken.count == 16)
        var responder = state
        responder.ephemeral = ephemeral
        var payload = ByteWriter()
        payload.u32(sessionID)
        payload.append(resetToken)
        payload.append(accepted.encoded)
        guard let message = responder.writeMessageB(payload: payload.bytes, remote: remoteEphemeral) else { return nil }
        let response = [Handshake.PacketType.response, Handshake.version] + message
        guard response.count <= datagram.count else { return nil }
        let (c2h, h2c) = responder.symmetric.split()
        return Accepted(response: response, sendKey: h2c, receiveKey: c2h, handshakeHash: responder.handshakeHash)
    }
}
