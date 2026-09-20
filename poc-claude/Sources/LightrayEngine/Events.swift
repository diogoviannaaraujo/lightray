import LightrayCore

/// A frame the app hands to the protocol. The storage is retained, not copied,
/// until the frame leaves the retransmit window.
public struct EncodedFrame: Sendable {
    public var stream: UInt8
    public var storage: any ByteStorage
    public var frameType: FrameType
    public var refKind: RefKind
    public var refFrameID: UInt32?
    public var ltrMark: Bool
    public var captureTimeMicros: UInt32
    /// HEVC VPS+SPS+PPS. Required on every IDR: they are not in-band in slice
    /// data, and a joining or rebuilt decoder cannot be created without them.
    public var codecConfig: [UInt8]?

    public init(stream: UInt8, storage: any ByteStorage, frameType: FrameType,
                refKind: RefKind = .previous, refFrameID: UInt32? = nil, ltrMark: Bool = true,
                captureTimeMicros: UInt32 = 0, codecConfig: [UInt8]? = nil) {
        self.stream = stream
        self.storage = storage
        self.frameType = frameType
        self.refKind = refKind
        self.refFrameID = refFrameID
        self.ltrMark = ltrMark
        self.captureTimeMicros = captureTimeMicros
        self.codecConfig = codecConfig
    }
}

/// A completed frame handed to the app. A class, so the app can hold it across
/// an asynchronous decode: a `RawSpan` is non-escapable and cannot survive that,
/// and the pooled buffer returns itself when the last reference goes away.
public final class ReceivedFrame {
    public let stream: UInt8
    public let frameID: UInt32
    public let header: FrameHeader
    public let arrivedAt: Instant
    /// Submit-to-complete latency measured from the first fragment's arrival.
    public let completionLatency: Interval

    private let buffer: UnsafeMutableRawBufferPointer
    private let codecConfigRange: Range<Int>?
    private let payloadRange: Range<Int>
    private let returnBuffer: (@Sendable (UnsafeMutableRawBufferPointer) -> Void)?

    init(stream: UInt8, frameID: UInt32, header: FrameHeader, arrivedAt: Instant,
         completionLatency: Interval, buffer: UnsafeMutableRawBufferPointer,
         codecConfigRange: Range<Int>?, payloadRange: Range<Int>,
         returnBuffer: (@Sendable (UnsafeMutableRawBufferPointer) -> Void)?) {
        self.stream = stream
        self.frameID = frameID
        self.header = header
        self.arrivedAt = arrivedAt
        self.completionLatency = completionLatency
        self.buffer = buffer
        self.codecConfigRange = codecConfigRange
        self.payloadRange = payloadRange
        self.returnBuffer = returnBuffer
    }

    deinit { returnBuffer?(buffer) }

    /// The codec payload, without the protocol's frame header.
    public var payload: UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(rebasing: buffer[payloadRange])
    }

    /// Present on every IDR: the parameter sets a decoder needs to be built.
    public var codecConfig: UnsafeRawBufferPointer? {
        guard let r = codecConfigRange else { return nil }
        return UnsafeRawBufferPointer(rebasing: buffer[r])
    }

    public var isKeyframe: Bool { header.isKeyframe }
}

/// What the engine tells the app about.
public enum ConnectionEvent {
    case established(sessionID: UInt32, config: SessionConfig, capabilities: Capabilities)
    case frameReceived(ReceivedFrame)
    /// A frame the receiver gave up on. On a realtime stream this is the cue for
    /// packet-loss concealment.
    case frameGap(stream: UInt8, frameID: UInt32)
    /// A frame arrived that the decoder must not see, because its references are
    /// missing. Held back until an IDR or a frame referencing an acked LTR.
    case frameUndecodable(stream: UInt8, frameID: UInt32)
    case datagramReceived(stream: UInt8, bytes: [UInt8])
    case reliableMessage(stream: UInt8, bytes: [UInt8])
    /// The app must produce a recovery frame. With `.ltr`, `ltrCandidates` is the
    /// whole retained acked set: the encoder picks and does not report its choice.
    case refreshRequired(stream: UInt8, preference: RefreshPreference, ltrCandidates: [UInt32])
    /// The app should pause its encoder and capture but keep them alive.
    case parked
    /// Parked long enough that the app should tear the pipeline down. The session
    /// survives, so a client returning later still resumes.
    case pipelineIdle
    case resumed
    case expired
    case rebound(PeerAddress)
    /// The client learned its session is gone; the app should re-handshake.
    case sessionLost
    case bitrateChanged(UInt32, reason: BitrateChangeReason)
    case configurationChanged(SessionConfig)
    case reconfigureResult(reqID: UInt32, config: SessionConfig, rejectedMask: UInt32)
    case closed(CloseCode)
}

/// A datagram the engine wants sent.
public struct Outgoing {
    public var length: Int
    public var destination: PeerAddress
    public init(length: Int, destination: PeerAddress) {
        self.length = length; self.destination = destination
    }
}
