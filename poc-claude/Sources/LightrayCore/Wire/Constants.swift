/// Wire-format constants for protocol v0.
///
/// The version byte pins the codecs: v0 means H.265 video and Opus audio at
/// 48 kHz / 20 ms. Nothing on the wire carries a codec identifier, so a peer that
/// disagrees about codecs fails the version check instead of negotiating.
public enum Wire {
    public static let version: UInt8 = 0

    public static let defaultMaxDatagramSize = 1200
    public static let minMaxDatagramSize = 512
    public static let maxMaxDatagramSize = 1452

    public static let headerSize = 16
    public static let tagSize = 16
    public static let chunkHeaderSize = 3
    /// stream, flags, frame_id, index, count, stride, ext_len
    public static let fragmentHeaderSize = 13
    /// The FEC TLV v0 always writes: {type 0x01, len 1, scheme NONE}.
    public static let fecTLVSize = 3

    /// Payload bytes a MEDIA_FRAGMENT carries in a datagram of `maxDatagramSize`.
    /// 1149 at the 1200-byte default, or 96% of the datagram.
    @inlinable
    public static func maxFragmentPayload(maxDatagramSize: Int) -> Int {
        maxDatagramSize - headerSize - tagSize - chunkHeaderSize - fragmentHeaderSize - fecTLVSize
    }

    /// Room for chunks inside a protected datagram.
    @inlinable
    public static func maxChunkSpace(maxDatagramSize: Int) -> Int {
        maxDatagramSize - headerSize - tagSize
    }

    /// The smallest datagram that can carry a protected packet: header + tag.
    public static let minProtectedSize = headerSize + tagSize
}

public enum ChunkType: UInt8, Sendable, CaseIterable {
    case mediaFragment = 0x01
    case reliable = 0x02
    case datagram = 0x03
    case feedback = 0x10
    case nack = 0x11
    case frameAck = 0x12
    case refreshRequest = 0x13
    case ping = 0x30
    case pong = 0x31
    case park = 0x32
    case resume = 0x33
    case close = 0x34
}

public enum HandshakeType: UInt8, Sendable {
    case initPacket = 0x80
    case response = 0x81
    case sessionUnknown = 0x82
}

/// MEDIA_FRAGMENT flag bits.
public struct FragmentFlags: OptionSet, Sendable {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let keyframe = FragmentFlags(rawValue: 1 << 0)
    public static let retransmission = FragmentFlags(rawValue: 1 << 1)
    /// Set on the fragment that carries the start of the frame header.
    public static let frameStart = FragmentFlags(rawValue: 1 << 2)
}

public enum FrameType: UInt8, Sendable {
    case idr = 0
    case predicted = 1
}

/// How a frame references earlier frames. `ltrAny` carries no id: the encoder
/// picked from the acked set and does not report which one, and the receiver
/// accepts it unconditionally because it only ever acks frames it decoded.
public enum RefKind: UInt8, Sendable {
    case none = 0
    case previous = 1
    case ltr = 2
    case ltrAny = 3
}

public struct FrameFlags: OptionSet, Sendable {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    /// The encoder marked this frame as an LTR candidate.
    public static let ltrMark = FrameFlags(rawValue: 1 << 0)
}

public enum FrameAckStatus: UInt8, Sendable {
    case received = 0
    /// On an LTR-marked frame, this is the LTR ack.
    case decoded = 1
}

public enum RefreshReason: UInt8, Sendable {
    case loss = 0
    case decoderReset = 1
    case resume = 2
}

public enum RefreshPreference: UInt8, Sendable {
    case ltr = 0
    case idr = 1
}

public struct ResumeFlags: OptionSet, Sendable {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let decoderLost = ResumeFlags(rawValue: 1 << 0)
}

public enum CloseCode: UInt16, Sendable {
    case normal = 0
    case appRequest = 1
    case timeout = 2
    case protocolViolation = 3
    case versionMismatch = 4
    case goingAway = 5
}

/// Stream kinds. The codec follows from the kind and the wire version, so there
/// is no per-stream codec tag.
public enum StreamKind: UInt8, Sendable {
    case video = 0
    case audio = 1
    case input = 2
    case mic = 3
    case camera = 4
    case data = 5
}

public enum StreamDirection: UInt8, Sendable {
    case hostToClient = 0
    case clientToHost = 1
}

/// How the per-stream machinery treats a stream.
public enum StreamClass: UInt8, Sendable {
    /// Fragmented, NACK, deadline, decodability gating.
    case media = 0
    /// Small frames; NACK within the deadline; gaps reported for concealment.
    case realtime = 1
    /// Ordered and acknowledged.
    case reliable = 2
    case unreliable = 3
}

public struct StreamDescriptor: Sendable, Equatable {
    public var id: UInt8
    public var kind: StreamKind
    public var direction: StreamDirection
    public var streamClass: StreamClass

    public init(id: UInt8, kind: StreamKind, direction: StreamDirection, streamClass: StreamClass) {
        self.id = id; self.kind = kind; self.direction = direction; self.streamClass = streamClass
    }
}

/// Capabilities offered in INIT and accepted in RESPONSE.
public struct Capabilities: OptionSet, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let ltr = Capabilities(rawValue: 1 << 0)
    /// Reserved: VideoToolbox has no intra-refresh property, so v0 never accepts it.
    public static let intraRefresh = Capabilities(rawValue: 1 << 1)
    public static let fec = Capabilities(rawValue: 1 << 2)
}
