import LightrayCore

/// Every tunable the engines read. Defaults are the values in the protocol plan.
public struct EngineConfig: Sendable {
    // MARK: Reconnect
    /// The host parks a session after this much silence, if no PARK arrived first.
    /// The client keeps the link warm with FEEDBACK or 250 ms PINGs.
    public var parkAfterSilence: Interval = .seconds(2)
    /// After this long parked, the host emits `.idle` so the app tears down its
    /// encoder and capture. The session itself is untouched.
    public var pipelineIdleAfter: Interval = .seconds(60)
    /// In host-running time. When it expires the session and its keys are gone.
    /// Affordable at 30 minutes only because parking released the media buffers.
    public var graceWindow: Interval = .seconds(30 * 60)
    public var maxParkedSessions = 8
    public var keepaliveInterval: Interval = .milliseconds(250)
    /// RESUME and INIT retransmission backoff.
    public var handshakeRetryInitial: Interval = .milliseconds(100)
    public var handshakeRetryMax: Interval = .seconds(2)

    // MARK: Recovery
    /// A gap is not a loss until the reorder window has passed.
    public var reorderWindow: Interval = .milliseconds(1)
    /// NACK retry period floor; the real period is max(1.5·srtt, this).
    public var nackRetryFloor: Interval = .milliseconds(2)
    /// Frame deadline, in frame intervals.
    public var frameDeadlineIntervals: UInt64 = 3
    public var retransmitStoreDuration: Interval = .milliseconds(500)
    public var retransmitStoreBytes = 16 << 20
    /// At most one LTR ack per this interval, which bounds FRAME_ACK traffic to
    /// 4/s rather than the frame rate.
    public var ltrAckInterval: Interval = .milliseconds(250)
    public var maxAckedLTR = 16
    /// Forces IDR-only recovery even when LTR was negotiated.
    public var forceIDROnly = false
    /// Reassembly slots per media stream.
    public var maxFramesInFlight = 8

    // MARK: Pacing and bitrate
    public var pacingGain: Double = 1.25
    /// The pacer spreads one frame's bytes over this fraction of a frame interval.
    public var spreadTarget: Double = 0.8
    /// Momentary ceiling, so a 500 KB IDR cannot demand an unbounded burst.
    public var linkRateCeiling: UInt64 = 400_000_000
    public var maxBurstBytes = 32 * 1500
    /// Loss backstop: clamp to the floor after N consecutive windows above the
    /// threshold. There is no automatic ramp-up.
    public var lossBackstopThreshold: Double = 0.10
    public var lossBackstopWindows = 4
    public var lossWindow: Interval = .milliseconds(500)

    // MARK: Feedback
    public var feedbackInterval: Interval = .milliseconds(20)
    /// Datagram size the engine assumes until the handshake settles it.
    public var maxDatagramSize = Wire.defaultMaxDatagramSize

    public init() {}
}

/// Why the bitrate changed.
public enum BitrateChangeReason: Sendable, Equatable {
    case manual
    case lossBackstop
}

public enum ConnectionRole: Sendable, Equatable {
    case host
    case client
}

public enum ConnectionState: String, Sendable, Equatable {
    case idle
    case handshaking
    case established
    case parked
    case pipelineIdle
    case closed
}
