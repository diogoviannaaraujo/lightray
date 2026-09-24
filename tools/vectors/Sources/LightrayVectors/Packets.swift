/// The 16-byte cleartext header of a protected packet, as `docs/packets.md` defines it.
public struct ProtectedHeader: Sendable, Equatable {
    public var flags: UInt8
    public var sessionID: UInt32
    public var transportSeq: UInt32
    public var sendTimeMicros: UInt32

    public init(flags: UInt8 = 0, sessionID: UInt32, transportSeq: UInt32, sendTimeMicros: UInt32) {
        self.flags = flags
        self.sessionID = sessionID
        self.transportSeq = transportSeq
        self.sendTimeMicros = sendTimeMicros
    }

    public init?(_ bytes: Bytes) {
        guard bytes.count >= Packet.headerLength else { return nil }
        flags = bytes[0]
        sessionID = UInt32(readBE(bytes[4..<8]))
        transportSeq = UInt32(readBE(bytes[8..<12]))
        sendTimeMicros = UInt32(readBE(bytes[12..<16]))
    }

    public var bytes: Bytes { [flags, 0, 0, 0] + be32(sessionID) + be32(transportSeq) + be32(sendTimeMicros) }
}

public enum Packet {
    public static let headerLength = 16
    public static let minimumLength = headerLength + Noise.tagLength

    public enum ChunkType {
        public static let padding: UInt8 = 0x00
        public static let close: UInt8 = 0x34
    }

    public enum CloseCode {
        public static let normal: UInt16 = 0
        public static let appRequest: UInt16 = 1
        public static let timeout: UInt16 = 2
        public static let protocolViolation: UInt16 = 3
        public static let versionMismatch: UInt16 = 4
        public static let goingAway: UInt16 = 5
    }

    public static func close(_ code: UInt16) -> Bytes { tlv(ChunkType.close, be16(code)) }

    /// Seals `chunks` under a transport key. The header is the associated data and the packet
    /// number is the nonce.
    public static func seal(header: ProtectedHeader, packetNumber: UInt64, key: Bytes, chunks: Bytes) -> Bytes {
        precondition(UInt32(truncatingIfNeeded: packetNumber) == header.transportSeq)
        precondition(packetNumber < UInt64.max)
        let aad = header.bytes
        return aad + Noise.encrypt(key: key, nonce: packetNumber, ad: aad, plaintext: chunks)
    }

    /// Opens a protected packet, reconstructing its packet number from `expected`.
    public static func open(_ datagram: Bytes, key: Bytes, expected: UInt64)
        -> (header: ProtectedHeader, packetNumber: UInt64, chunks: Bytes)?
    {
        guard datagram.count >= minimumLength, datagram[0] & 0x80 == 0,
            let header = ProtectedHeader(datagram)
        else { return nil }
        let packetNumber = reconstruct(expected: expected, transportSeq: header.transportSeq)
        guard
            let chunks = Noise.decrypt(
                key: key, nonce: packetNumber, ad: Array(datagram[0..<headerLength]),
                ciphertext: Array(datagram[headerLength...]))
        else { return nil }
        return (header, packetNumber, chunks)
    }

    /// The 64-bit packet number congruent to `transportSeq` modulo 2³² that is nearest to
    /// `expected`, one greater than the highest packet number authenticated so far (0 at first).
    public static func reconstruct(expected: UInt64, transportSeq: UInt32) -> UInt64 {
        let window: UInt64 = 1 << 32
        let half: UInt64 = 1 << 31
        let candidate = (expected & ~(window - 1)) | UInt64(transportSeq)
        if expected >= candidate, expected - candidate >= half, candidate <= UInt64.max - window {
            return candidate + window
        }
        if candidate > expected, candidate - expected > half, candidate >= window {
            return candidate - window
        }
        return candidate
    }
}
