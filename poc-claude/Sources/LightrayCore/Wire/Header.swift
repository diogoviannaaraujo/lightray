/// The 16-byte cleartext header of a protected packet, authenticated as AAD.
///
/// | 0 | flags | bit7 = 0 (short form), bit6 = key_phase (reserved) |
/// | 1 | reserved[3] | room for CC/FEC signalling without a version bump |
/// | 4 | session_id:u32 | |
/// | 8 | transport_seq:u32 | low 32 bits of a per-direction u64 |
/// | 12 | send_time_us:u32 | sender's monotonic clock; only deltas are used |
public struct PacketHeader: Equatable, Sendable {
    public static let size = Wire.headerSize

    public var flags: UInt8
    public var sessionID: UInt32
    public var transportSeq: UInt32
    public var sendTimeMicros: UInt32

    @inlinable
    public init(flags: UInt8 = 0, sessionID: UInt32, transportSeq: UInt32, sendTimeMicros: UInt32) {
        self.flags = flags
        self.sessionID = sessionID
        self.transportSeq = transportSeq
        self.sendTimeMicros = sendTimeMicros
    }

    @inlinable public var keyPhase: Bool { flags & 0x40 != 0 }

    /// Distinguishes a protected packet from a handshake packet without parsing.
    @inlinable public static func isHandshake(firstByte: UInt8) -> Bool { firstByte & 0x80 != 0 }

    @inlinable
    public static func decode(_ r: inout ByteReader) throws(WireError) -> PacketHeader {
        let flags = try r.u8()
        guard flags & 0x80 == 0 else { throw .malformed }
        try r.skip(3)
        return PacketHeader(flags: flags,
                            sessionID: try r.u32(),
                            transportSeq: try r.u32(),
                            sendTimeMicros: try r.u32())
    }

    @inlinable
    public func encode(into w: inout ByteWriter) throws(WireError) {
        try w.put(flags)
        try w.put(UInt8(0))
        try w.put(UInt16(0))
        try w.put(sessionID)
        try w.put(transportSeq)
        try w.put(sendTimeMicros)
    }

    /// Reads `session_id` from a datagram without authenticating it, so the host
    /// can route a packet to a session before it has keys to check it with.
    @inlinable
    public static func peekSessionID(_ datagram: UnsafeRawBufferPointer) -> UInt32? {
        guard datagram.count >= Wire.headerSize, !isHandshake(firstByte: datagram[0]) else { return nil }
        return UInt32(bigEndian: datagram.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
    }

    @inlinable
    public static func peekTransportSeq(_ datagram: UnsafeRawBufferPointer) -> UInt32? {
        guard datagram.count >= Wire.headerSize, !isHandshake(firstByte: datagram[0]) else { return nil }
        return UInt32(bigEndian: datagram.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
    }
}
