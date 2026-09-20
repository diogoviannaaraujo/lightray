import CryptoKit
import LightrayCore
import LightrayCrypto
import LightrayEngine

/// A whole host and client, wired through a simulated link, driven on a virtual
/// clock. Every scenario test is written against this.
public final class Harness {
    public let clock = ManualClock()
    public let network: SimulatedNetwork
    public let host: HostEndpoint
    public let client: ClientEndpoint
    public let hostPool = BufferPool()
    public let clientPool = BufferPool()

    public private(set) var hostAddress = PeerAddress.synthetic(1, port: 7000)
    public private(set) var clientAddress = PeerAddress.synthetic(2, port: 50000)
    private var clientPortCounter: UInt16 = 50000

    /// What the app would do: answer a refresh request with the frame it asks
    /// for, and report every delivered frame decoded.
    public var autoRespondToRefresh = true
    public var autoReportDecoded = true
    /// The app pauses its encoder and capture on `.parked` and starts again on
    /// `.resumed`, which is what the event is for.
    public var autoPauseOnPark = true
    /// Frames the host produces each frame interval while `streaming` is on.
    public var streaming = false

    public var videoSource: SyntheticFrameSource
    public var audioSource: SyntheticFrameSource?
    /// The reverse direction: mic and camera use the same machinery.
    public var clientSources: [SyntheticFrameSource] = []

    public struct DeliveredFrame: Equatable {
        public var stream: UInt8
        public var frameID: UInt32
        public var isKeyframe: Bool
        public var refKind: RefKind
        public var byteCount: Int
        public var hadCodecConfig: Bool
        public var latency: Interval
        public var at: Instant
        public var firstPayloadWord: UInt32
    }

    public private(set) var delivered: [DeliveredFrame] = []
    public private(set) var hostEvents: [(UInt32, String)] = []
    public private(set) var clientEvents: [String] = []
    public private(set) var undecodable: [(UInt8, UInt32)] = []
    public private(set) var gaps: [(UInt8, UInt32)] = []
    public private(set) var refreshRequests: [(UInt8, RefreshPreference, [UInt32])] = []
    public private(set) var clientRefreshRequests: [(UInt8, RefreshPreference)] = []
    public private(set) var hostSubmittedIDRs = 0
    public private(set) var parkedCount = 0
    public private(set) var pipelineIdleCount = 0
    public private(set) var resumedCount = 0
    public private(set) var expiredCount = 0
    public private(set) var reboundCount = 0
    public private(set) var sessionLostCount = 0
    public private(set) var backstopEvents: [UInt32] = []
    public private(set) var clientConfigs: [SessionConfig] = []
    public private(set) var reconfigureResults: [(UInt32, SessionConfig, UInt32)] = []
    public private(set) var hostReliableMessages: [(UInt8, [UInt8])] = []
    public private(set) var clientReliableMessages: [(UInt8, [UInt8])] = []

    private let sendBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 64)
    private var nextFrameAt: Instant = .zero
    private var pendingHostIDR: Set<UInt8> = []
    private var pendingHostLTR: [UInt8: [UInt32]] = [:]
    private var wasStreamingBeforePark = false

    public let streams: [StreamDescriptor]

    public init(seed: UInt64 = 0x5EED,
                hostToClient: SimulatedNetwork.LinkModel = .clean(),
                clientToHost: SimulatedNetwork.LinkModel = .clean(),
                config: SessionConfig = SessionConfig(),
                engine: EngineConfig = EngineConfig(),
                capabilities: Capabilities = [.ltr],
                streams: [StreamDescriptor]? = nil) {
        self.network = SimulatedNetwork(seed: seed, hostToClient: hostToClient, clientToHost: clientToHost)
        self.streams = streams ?? [
            StreamDescriptor(id: 1, kind: .video, direction: .hostToClient, streamClass: .media),
            StreamDescriptor(id: 2, kind: .audio, direction: .hostToClient, streamClass: .realtime),
            StreamDescriptor(id: 3, kind: .input, direction: .clientToHost, streamClass: .reliable),
        ]
        let psk = SymmetricKey(data: [UInt8](repeating: 0x42, count: 32))
        self.host = HostEndpoint(psk: psk, streams: self.streams, config: config, engine: engine,
                                 pool: hostPool, capabilities: capabilities, at: clock.now())
        self.client = ClientEndpoint(psk: psk, pairingID: 0xA11CE, streams: self.streams,
                                     config: config, engine: engine, pool: clientPool,
                                     capabilities: capabilities)
        self.videoSource = SyntheticFrameSource(stream: 1, bitrate: config.bitrate,
                                                framerate: config.framerate, seed: seed &+ 1)
        self.nextFrameAt = clock.now()
    }

    deinit { sendBuffer.deallocate() }

    public var now: Instant { clock.now() }

    // MARK: - Driving

    /// Starts the handshake and runs until it completes, so a test never has to
    /// guess how long a lossy link takes to get an INIT through.
    public func connect(timeout: Interval = .seconds(5)) {
        client.connect(to: hostAddress, at: now)
        pump()
        let deadline = now + timeout
        while client.phase == .handshaking, now < deadline {
            run(until: min(now + .milliseconds(5), deadline))
        }
    }

    /// Starts the synthetic host stream.
    public func startStreaming() {
        streaming = true
        wasStreamingBeforePark = true
        nextFrameAt = now
    }

    /// Stops it, and stops the park/resume hook restarting it.
    public func stopStreaming() {
        streaming = false
        wasStreamingBeforePark = false
    }

    /// Cuts the link in both directions for `duration`, as a blackout does.
    public func blackout(_ duration: Interval) {
        let window = (start: now, end: now + duration)
        network.hostToClient.blackout = window
        network.clientToHost.blackout = window
    }

    /// Cuts one direction only, which is how a burst of loss on the video path
    /// is modelled without touching feedback.
    public func blackout(direction: SimulatedNetwork.Direction, for duration: Interval) {
        let window = (start: now, end: now + duration)
        switch direction {
        case .hostToClient: network.hostToClient.blackout = window
        case .clientToHost: network.clientToHost.blackout = window
        }
    }

    public func endBlackout() {
        network.hostToClient.blackout = nil
        network.clientToHost.blackout = nil
    }

    /// Frames delivered at or after `instant`.
    public func frames(since instant: Instant) -> [DeliveredFrame] {
        delivered.filter { $0.at >= instant }
    }

    /// Runs the world forward by `duration`, stopping at every event.
    public func advance(_ duration: Interval) {
        run(until: now + duration)
    }

    /// Jumps from armed event to armed event, so a 30-minute grace window costs
    /// a handful of steps rather than millions of ticks.
    public func run(until target: Instant) {
        pump()
        var steps = 0
        while now < target {
            steps += 1
            precondition(steps < 5_000_000, "harness made no progress towards \(target.nanos)")
            let wake = nextWake()
            if let w = wake, w > now {
                clock.set(min(w, target))
            } else if wake != nil {
                // Something says it is due now but the pump could not act on it
                // (usually a pacer waiting on sub-tick tokens): nudge the clock.
                clock.set(min(now + .microseconds(100), target))
            } else {
                clock.set(target)
            }
            pump()
        }
    }

    private func nextWake() -> Instant? {
        var candidates: [Instant] = []
        if let t = network.nextDelivery() { candidates.append(t) }
        if let t = host.nextTimeout(at: now) { candidates.append(max(t, now)) }
        if let t = client.nextTimeout(at: now) { candidates.append(max(t, now)) }
        if streaming, client.phase == .connected { candidates.append(max(nextFrameAt, now)) }
        return candidates.min()
    }

    /// Delivers, times out, transmits and drains events until nothing changes.
    ///
    /// Timers are evaluated once per instant — they are functions of the clock,
    /// so re-running them inside the cascade only costs time — while delivery and
    /// transmission loop until quiescent.
    public func pump() {
        host.handleTimeout(at: now)
        client.handleTimeout(at: now)
        for _ in 0..<10_000 {
            var progressed = false

            for packet in network.takeDeliverable(upTo: now) {
                packet.bytes.withUnsafeBytes { raw in
                    switch packet.direction {
                    case .clientToHost:
                        host.handle(datagram: raw, from: packet.source, at: now)
                    case .hostToClient:
                        client.handle(datagram: raw, from: packet.source, at: now)
                    }
                }
                progressed = true
            }

            if streaming, client.phase == .connected, now >= nextFrameAt {
                produceFrame()
                nextFrameAt = now + frameInterval
                progressed = true
            }
            if !pendingHostIDR.isEmpty { produceRefreshFrames(); progressed = true }

            while let out = host.pollTransmit(into: sendBuffer, at: now) {
                network.send(UnsafeRawBufferPointer(rebasing: sendBuffer[..<out.length]),
                             direction: .hostToClient, source: hostAddress, at: now)
                progressed = true
            }
            if client.wantsFreshSocket { replaceClientSocket() }
            while let out = client.pollTransmit(into: sendBuffer, at: now) {
                network.send(UnsafeRawBufferPointer(rebasing: sendBuffer[..<out.length]),
                             direction: .clientToHost, source: clientAddress, at: now)
                progressed = true
            }

            if drainEvents() { progressed = true }
            if !progressed { return }
        }
    }

    public var frameInterval: Interval {
        client.connection?.config.frameInterval ?? Interval(nanos: 16_666_667)
    }

    /// The runtime's job in production: a resume needs a new source port so the
    /// host sees a rebind.
    public func replaceClientSocket() {
        clientPortCounter += 1
        clientAddress = PeerAddress.synthetic(2, port: clientPortCounter)
        client.acknowledgeFreshSocket()
    }

    // MARK: - App behaviour

    private func produceFrame() {
        guard let connection = client.connection else { return }
        _ = connection
        let frame = videoSource.next(at: now)
        if frame.frameType == .idr { hostSubmittedIDRs += 1 }
        submitToHost(frame)
        if var audio = audioSource {
            let a = audio.next(at: now)
            submitToHost(a)
            audioSource = audio
        }
        for i in clientSources.indices {
            let f = clientSources[i].next(at: now)
            client.submit(f, at: now)
        }
    }

    /// Reliable input, in the client-to-host direction.
    public func sendInput(_ bytes: [UInt8], stream: UInt8) {
        client.sendReliable(bytes, stream: stream)
    }

    private func produceRefreshFrames() {
        let streams = pendingHostIDR
        pendingHostIDR.removeAll()
        for stream in streams {
            let candidates = pendingHostLTR[stream] ?? []
            pendingHostLTR[stream] = nil
            var frame = videoSource.next(at: now, forceIDR: candidates.isEmpty, ltrCandidates: candidates)
            frame.stream = stream
            if frame.frameType == .idr { hostSubmittedIDRs += 1 }
            submitToHost(frame)
        }
    }

    public func submitToHost(_ frame: EncodedFrame) {
        for id in host.activeSessionIDs {
            host.connection(id)?.submit(frame, at: now)
        }
    }

    @discardableResult
    private func drainEvents() -> Bool {
        var any = false
        while let e = host.pollEvent() {
            any = true
            hostEvents.append((e.sessionID, describe(e.event)))
            switch e.event {
            case .parked:
                parkedCount += 1
                if autoPauseOnPark { streaming = false }
            case .pipelineIdle: pipelineIdleCount += 1
            case .resumed:
                resumedCount += 1
                if autoPauseOnPark, wasStreamingBeforePark { streaming = true; nextFrameAt = now }
            case .expired: expiredCount += 1
            case .rebound: reboundCount += 1
            case .refreshRequired(let stream, let preference, let candidates):
                refreshRequests.append((stream, preference, candidates))
                if autoRespondToRefresh {
                    pendingHostIDR.insert(stream)
                    pendingHostLTR[stream] = preference == .ltr ? candidates : []
                }
            case .bitrateChanged(let bps, let reason):
                if reason == .lossBackstop { backstopEvents.append(bps) }
            case .reliableMessage(let stream, let bytes):
                hostReliableMessages.append((stream, bytes))
            case .frameReceived(let frame):
                // The host receives the client's reverse streams.
                record(frame)
                if autoReportDecoded {
                    host.connection(e.sessionID)?.reportDecoded(stream: frame.stream,
                                                                frameID: frame.frameID, at: now)
                }
            default: break
            }
        }
        while let e = client.pollEvent() {
            any = true
            clientEvents.append(describe(e))
            switch e {
            case .frameReceived(let frame):
                record(frame)
                if autoReportDecoded {
                    client.reportDecoded(stream: frame.stream, frameID: frame.frameID, at: now)
                }
            case .reliableMessage(let stream, let bytes):
                clientReliableMessages.append((stream, bytes))
            case .frameUndecodable(let stream, let id): undecodable.append((stream, id))
            case .frameGap(let stream, let id): gaps.append((stream, id))
            case .refreshRequired(let stream, let preference, _):
                clientRefreshRequests.append((stream, preference))
            case .sessionLost: sessionLostCount += 1
            case .configurationChanged(let config): clientConfigs.append(config)
            case .reconfigureResult(let id, let config, let mask):
                reconfigureResults.append((id, config, mask))
            case .bitrateChanged(let bps, let reason):
                if reason == .lossBackstop { backstopEvents.append(bps) }
            default: break
            }
        }
        return any
    }

    private func record(_ frame: ReceivedFrame) {
        var word: UInt32 = 0
        if frame.payload.count >= 4 {
            word = UInt32(bigEndian: frame.payload.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        }
        delivered.append(DeliveredFrame(stream: frame.stream, frameID: frame.frameID,
                                        isKeyframe: frame.isKeyframe, refKind: frame.header.refKind,
                                        byteCount: frame.payload.count,
                                        hadCodecConfig: frame.codecConfig != nil,
                                        latency: frame.completionLatency, at: now,
                                        firstPayloadWord: word))
    }

    private func describe(_ e: ConnectionEvent) -> String {
        switch e {
        case .established: return "established"
        case .frameReceived: return "frameReceived"
        case .frameGap: return "frameGap"
        case .frameUndecodable: return "frameUndecodable"
        case .datagramReceived: return "datagramReceived"
        case .reliableMessage: return "reliableMessage"
        case .refreshRequired(_, let p, _): return "refreshRequired(\(p))"
        case .parked: return "parked"
        case .pipelineIdle: return "pipelineIdle"
        case .resumed: return "resumed"
        case .expired: return "expired"
        case .rebound: return "rebound"
        case .sessionLost: return "sessionLost"
        case .bitrateChanged(_, let r): return "bitrateChanged(\(r))"
        case .configurationChanged: return "configurationChanged"
        case .reconfigureResult: return "reconfigureResult"
        case .closed: return "closed"
        }
    }

    // MARK: - Queries used by the scenario tests

    public var videoFrames: [DeliveredFrame] { delivered.filter { $0.stream == 1 } }
    public var keyframes: [DeliveredFrame] { delivered.filter { $0.isKeyframe } }
    public var hostConnection: Connection? { host.activeSessionIDs.first.flatMap { host.connection($0) } }
    public var hostNacksReceived: UInt64 { hostConnection?.path.nacksReceived ?? 0 }
    public var clientNacksSent: UInt64 { client.connection?.path.nacksSent ?? 0 }
    public var hostRetransmits: UInt64 { hostConnection?.path.retransmitsSent ?? 0 }
}
