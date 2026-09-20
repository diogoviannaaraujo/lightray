import LightrayCore
import LightrayCrypto

/// The protocol engine, shared by both roles.
///
/// Sans-IO: no sockets, no threads and no clock live inside it. Every input
/// carries `at:` and every output is polled, which makes it deterministic on a
/// virtual clock and lets benchmarks run the whole pipeline without a socket.
///
/// Not `Sendable`: one connection belongs to one loop thread.
public final class Connection {
    public let role: ConnectionRole
    public internal(set) var sessionID: UInt32
    public internal(set) var state: ConnectionState
    public internal(set) var peer: PeerAddress
    public internal(set) var config: SessionConfig
    public internal(set) var capabilities: Capabilities

    let engine: EngineConfig
    let protection: PacketProtection
    let pool: BufferPool
    /// Where delivered frames hand their buffers back, possibly from another
    /// thread. Drained on the loop thread.
    let reclaimer = BufferReclaimer()
    /// The reset token the RESPONSE handed over, so a SESSION_UNKNOWN can be
    /// told from an off-path forgery without any host secret.
    public var expectedResetToken: [UInt8] = []

    // MARK: Packet number spaces
    var nextTransportSeq: UInt64 = 0
    var replay = ReplayWindow()
    var lastTransitMicros: Int64?

    // MARK: Streams
    public internal(set) var streamTable: [StreamDescriptor]
    var reassemblers: [UInt8: Reassembler] = [:]
    var decodability: [UInt8: DecodabilityTracker] = [:]
    var ltrAcks: [UInt8: LTRAckSet] = [:]
    var nextFrameID: [UInt8: UInt32] = [:]
    var lastLTRAckAt: [UInt8: Instant] = [:]
    var pendingLTRAck: [UInt8: UInt32] = [:]
    /// One ordered channel per reliable stream. Stream 0 is the control
    /// channel; reliable input rides its own stream with the same machinery.
    var reliable: [UInt8: ReliableChannel] = [:]

    // MARK: Send path
    var queues = SendQueues()
    var retransmits: RetransmitStore
    var sentLog = SentPacketLog()
    var pacer: Pacer
    var bitrate: BitrateController
    var plaintextScratch: UnsafeMutableRawBufferPointer
    var receiveScratch: UnsafeMutableRawBufferPointer

    // MARK: Receive path
    var arrivals = ArrivalLog()
    /// Completed frames waiting for their turn, per stream, ordered by frame id.
    ///
    /// A small P-frame can finish before the 500 KB IDR it follows — the pacer
    /// is still spreading the IDR, or one of its fragments is being retransmitted.
    /// Discarding the P-frame then would throw away a frame that is a millisecond
    /// away from being decodable, so it waits here until its predecessor lands or
    /// its own deadline passes.
    var held: [UInt8: [HeldFrame]] = [:]

    // MARK: Timers
    var lastReceived: Instant
    var lastSent: Instant
    var nextFeedbackAt: Instant
    var nextKeepaliveAt: Instant
    var parkedAt: Instant?
    var pipelineIdleEmitted = false
    var resumeRequestedAt: Instant?
    var nextResumeRetryAt: Instant?
    var resumeBackoff: Interval
    var awaitingResumeState = false

    // MARK: Pending control
    var pendingFeedback = false
    var pendingPings: [UInt32] = []
    var pendingPongs: [(UInt32, Instant)] = []
    var pendingPark = false
    /// RESUME is re-armed by the retry timer rather than left set, so it is
    /// sent once per retry instead of riding every control datagram.
    var pendingResume = false
    var resumeFlags: ResumeFlags = []
    var pendingClose: CloseCode?
    var pendingNacks: [UInt8: [NackEntry]] = [:]
    var pendingFrameAcks: [FrameAckEntry] = []
    var pendingRefresh: [RefreshRequest] = []
    var pendingDatagrams: [(UInt8, [UInt8])] = []
    var pingSentAt: [UInt32: Instant] = [:]
    var nextPingID: UInt32 = 1
    var nextRefreshReqID: UInt32 = 1
    var nextReconfigureReqID: UInt32 = 1
    /// Set once CLOSE has been written, so the state change happens after it goes out.
    var closeSentCode: CloseCode?
    /// The reliable segment carried by the datagram currently being built, so a
    /// FEEDBACK ack for that packet can be credited to the segment rather than
    /// being lost because the datagram also carried other control chunks.
    var pendingReliableSeq: (stream: UInt8, msgSeq: UInt32, segIndex: UInt16)?

    // MARK: Observability
    /// The peer reported that its own sender is clamped to its bitrate floor.
    /// Durable, unlike the timeline ring, because a UI has to keep showing it.
    public internal(set) var peerBackstopEngaged = false
    public internal(set) var path = PathStats()
    public internal(set) var reconnect = ReconnectStats()
    public internal(set) var log = EventLog()
    var events = RingBuffer<ConnectionEvent>(capacity: 64)

    public init(role: ConnectionRole, sessionID: UInt32, protection: PacketProtection,
                streams: [StreamDescriptor], config: SessionConfig, capabilities: Capabilities,
                engine: EngineConfig, peer: PeerAddress, pool: BufferPool, at now: Instant) {
        self.role = role
        self.sessionID = sessionID
        self.protection = protection
        self.streamTable = streams
        self.config = config
        self.capabilities = capabilities
        self.engine = engine
        self.peer = peer
        self.pool = pool
        self.state = .established
        self.retransmits = RetransmitStore(duration: engine.retransmitStoreDuration,
                                           byteLimit: engine.retransmitStoreBytes)
        self.pacer = Pacer(rate: Pacer.rate(targetBitrate: config.bitrate, frameBytes: 0,
                                            frameInterval: config.frameInterval, config: engine),
                           maxBurstBytes: engine.maxBurstBytes, at: now)
        self.bitrate = BitrateController(target: config.bitrate, floor: config.bitrateFloor,
                                         config: engine, at: now)
        let size = Int(config.maxDatagramSize)
        self.plaintextScratch = .allocate(byteCount: size + 64, alignment: 64)
        self.receiveScratch = .allocate(byteCount: size + 64, alignment: 64)
        self.lastReceived = now
        self.lastSent = now
        self.nextFeedbackAt = now + engine.feedbackInterval
        self.nextKeepaliveAt = now + engine.keepaliveInterval
        self.resumeBackoff = engine.handshakeRetryInitial

        reliable[0] = ReliableChannel(stream: 0)
        for s in streams {
            if s.streamClass == .reliable { reliable[s.id] = ReliableChannel(stream: s.id) }
            if isInbound(s), s.streamClass == .media || s.streamClass == .realtime {
                reassemblers[s.id] = Reassembler(stream: s.id, pool: pool,
                                                 maxFramesInFlight: engine.maxFramesInFlight)
                // Only `media` streams are decodability-gated. A `realtime`
                // stream carries independent frames — an Opus packet references
                // nothing — so gating one would withhold audio that is perfectly
                // playable, and a gap there is concealed rather than refreshed.
                if s.streamClass == .media {
                    decodability[s.id] = DecodabilityTracker(
                        forceIDROnly: engine.forceIDROnly || !capabilities.contains(.ltr),
                        maxAckedLTR: engine.maxAckedLTR)
                }
            }
            if isOutbound(s) {
                ltrAcks[s.id] = LTRAckSet(limit: engine.maxAckedLTR)
                nextFrameID[s.id] = 1
            }
        }
        log.record(.established, at: now, detail: sessionID)
        events.push(.established(sessionID: sessionID, config: config, capabilities: capabilities))
    }

    deinit {
        plaintextScratch.deallocate()
        receiveScratch.deallocate()
    }

    func isOutbound(_ s: StreamDescriptor) -> Bool {
        role == .host ? s.direction == .hostToClient : s.direction == .clientToHost
    }

    func isInbound(_ s: StreamDescriptor) -> Bool { !isOutbound(s) }

    public var maxDatagramSize: Int { Int(config.maxDatagramSize) }
    public var targetBitrate: UInt32 { bitrate.target }
    public var backstopEngaged: Bool { bitrate.backstopEngaged }
    public var lastActivity: Instant { lastReceived }
    public var isParked: Bool { state == .parked || state == .pipelineIdle }

    /// Bytes of protocol state the session is holding. The park path asserts this
    /// falls to well under 1 KB plus stats.
    public var retainedMediaBytes: Int {
        retransmits.bytesHeld + queues.queuedBytes
    }

    // MARK: - Snapshot

    public func snapshot() -> StatsSnapshot {
        var s = StatsSnapshot()
        s.path = path
        s.reconnect = reconnect
        s.sessionID = sessionID
        s.state = state.rawValue
        s.targetBitrate = bitrate.target
        s.backstopEngaged = bitrate.backstopEngaged || peerBackstopEngaged
        s.timeline = log.events
        for (id, r) in reassemblers { s.streams[id] = r.stats }
        for (id, st) in _outboundStats { s.streams[id] = st }
        for s2 in streamTable where isOutbound(s2) {
            var st = s.streams[s2.id] ?? StreamStats()
            st.pacerQueueDepth = queues.queuedFrames
            st.pacerQueueBytes = queues.queuedBytes
            s.streams[s2.id] = st
        }
        s.path.reportedLoss = bitrate.lastWindowLoss
        return s
    }

    public func pollEvent() -> ConnectionEvent? { events.pop() }

    /// Mutable per-stream stats. Inbound streams keep theirs in the reassembler;
    /// outbound streams get a lazily created slot.
    func streamStats(_ id: UInt8) -> StreamStatsRef {
        StreamStatsRef(connection: self, stream: id)
    }

    var _outboundStats: [UInt8: StreamStats] = [:]

    func push(_ e: ConnectionEvent) { events.push(e) }
}

/// A write-through handle to one stream's counters, so call sites read as
/// `streamStats(id).framesSubmitted += 1` whichever side owns the storage.
@dynamicMemberLookup
struct StreamStatsRef {
    let connection: Connection
    let stream: UInt8

    subscript<T>(dynamicMember key: WritableKeyPath<StreamStats, T>) -> T {
        get { connection.stats(for: stream)[keyPath: key] }
        nonmutating set {
            var s = connection.stats(for: stream)
            s[keyPath: key] = newValue
            connection.setStats(s, for: stream)
        }
    }
}

extension Connection {
    func stats(for stream: UInt8) -> StreamStats {
        if let r = reassemblerFor(stream) { return r.stats }
        return _outboundStats[stream] ?? StreamStats()
    }

    func setStats(_ s: StreamStats, for stream: UInt8) {
        if let r = reassemblerFor(stream) { r.stats = s } else { _outboundStats[stream] = s }
    }

    func reassemblerFor(_ stream: UInt8) -> Reassembler? { reassemblers[stream] }
}

extension Connection {
    /// Adopts this session under fresh keys, which is what a re-handshake
    /// carrying `resume_session_id` produces.
    ///
    /// The session id, stream table, configuration and stats all survive; the
    /// packet-number space and replay window restart, because a nonce is only
    /// unique within one key.
    func adopt(send: DirectionKeys, receive: DirectionKeys, peer newPeer: PeerAddress, at now: Instant) {
        protection.rekey(send: send, receive: receive)
        nextTransportSeq = 0
        replay.reset()
        arrivals.reset()
        sentLog.reset()
        lastTransitMicros = nil
        peer = newPeer
        releaseMediaState()
        for id in reliable.keys { reliable[id]?.reset() }
        state = .established
        parkedAt = nil
        pipelineIdleEmitted = false
        lastReceived = now
        lastSent = now
        nextFeedbackAt = now + engine.feedbackInterval
        nextKeepaliveAt = now + engine.keepaliveInterval
        pacer.reset(at: now)
        bitrate.reset(at: now)
        reconnect.handshakesAdopted &+= 1
        log.record(.adopted, at: now, detail: sessionID)
    }

    /// Marks the session expired, which is the endpoint's cue to discard it.
    func expire(at now: Instant) {
        reconnect.sessionsExpired &+= 1
        log.record(.expired, at: now, detail: sessionID)
        state = .closed
        releaseMediaState()
        push(.expired)
    }
}

extension Connection {
    /// The acked-LTR set this sender retains for a stream, which bounds both the
    /// set itself and the FRAME_ACK traffic that feeds it.
    public func ackedLTRCount(stream: UInt8) -> Int { ltrAcks[stream]?.candidates.count ?? 0 }
    public func ackedLTR(stream: UInt8) -> [UInt32] { ltrAcks[stream]?.candidates ?? [] }
    /// Frames the receiver is holding back from the decoder right now.
    public func framesInFlight(stream: UInt8) -> Int { reassemblers[stream]?.framesInFlight ?? 0 }
}

/// A completed frame waiting for its turn in `frame_id` order.
struct HeldFrame {
    var frameID: UInt32
    var buffer: UnsafeMutableRawBufferPointer
    var byteCount: Int
    var firstArrival: Instant
    var deadline: Instant
    var keyframe: Bool
}

extension Connection {
    /// Reliable segments still waiting for an acknowledgement, for tests and the
    /// stats overlay.
    public func pendingReliableCount(stream: UInt8) -> Int { reliable[stream]?.pendingCount ?? 0 }
}
