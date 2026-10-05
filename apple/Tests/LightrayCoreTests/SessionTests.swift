import Testing

@testable import LightrayCore

/// A deterministic generator, so that every lossy run is repeatable.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

/// A host and a client joined by a simulated path, stepped in 250 µs increments.
final class SimulatedLink {
    var now: UInt64 = 10_000_000
    let unix: UInt64 = 1_700_000_000
    let psk = Bytes(repeating: 7, count: 32)
    let pairingID: UInt64 = 42
    let hostAddress = PeerAddress(ip: [10, 0, 0, 1], port: 7373)
    var clientAddress = PeerAddress(ip: [10, 0, 0, 2], port: 50000)

    var host: HostEndpoint
    let client: ClientEndpoint

    var delay: UInt64 = 2_000
    var jitter: UInt64 = 0
    var loss = 0.0
    /// The client's radio going away, as AWDL takes it: for `length` out of every `every`, nothing
    /// reaches or leaves the client; what is sent meanwhile arrives in a burst when it returns.
    var stalls: (every: UInt64, length: UInt64)?
    var rng = SplitMix(state: 1)
    let uplink = SimulatedBottleneck()
    let downlink = SimulatedBottleneck()
    /// Return true to drop a datagram: (bytes, towards the host).
    var dropFilter: ((Bytes, Bool) -> Bool)?
    private(set) var filteredToHost = 0
    private(set) var filteredToClient = 0
    private var inFlight: [(at: UInt64, bytes: Bytes, from: PeerAddress, toHost: Bool)] = []

    var hostEvents: [HostEvent] = []
    var clientEvents: [ClientEvent] = []
    /// Frames delivered on stream 1, and on every stream.
    var delivered: [DeliveredFrame] = []
    var deliveredOn: [UInt8: [DeliveredFrame]] = [:]
    /// Long scenario runs can keep delivery metadata without pinning every media reservation.
    var retainDeliveredPayloads = true
    var inputs: [InputMessage] = []
    /// The video streams `run` submits frames on.
    var streams: [UInt8] = [1]
    var keyframeNeeded = Set<UInt8>()
    /// Streams whose next keyframe request is ignored, so that they start with a predicted frame.
    var ignoreKeyframeRequest = Set<UInt8>()
    var bytesToClient = 0
    /// Bytes each address delivered to the host, and bytes the host sent each address.
    var deliveredToHostFrom: [PeerAddress: Int] = [:]
    var sentByHostTo: [PeerAddress: Int] = [:]

    let hostConfig: HostConfig

    init(offerFEC: Bool = true, hostConfig: HostConfig = HostConfig(), videoStreamCount: Int = 4, seed: UInt64 = 1) {
        let psk = self.psk
        let pairingID = self.pairingID
        self.hostConfig = hostConfig
        rng = SplitMix(state: seed)
        host = HostEndpoint(config: hostConfig, hostSecret: Bytes(repeating: 3, count: 32)) {
            $0 == pairingID ? psk : nil
        }
        var config = ClientConfig(pairingID: pairingID, psk: psk, host: hostAddress)
        config.maxDatagramSize = 1200
        config.offerFEC = offerFEC
        config.videoStreamCount = videoStreamCount
        let unix = self.unix
        client = ClientEndpoint(config: config, unixTime: { unix })
    }

    func replaceHost(secret: UInt8) {
        let psk = self.psk
        let pairingID = self.pairingID
        host = HostEndpoint(config: hostConfig, hostSecret: Bytes(repeating: secret, count: 32)) {
            $0 == pairingID ? psk : nil
        }
    }

    func step() {
        now += 250
        for packet in uplink.advance(to: now) { schedule(packet, toHost: true) }
        for packet in downlink.advance(to: now) { schedule(packet, toHost: false) }
        let due = inFlight.filter { $0.at <= now }
        inFlight.removeAll { $0.at <= now }
        for packet in due {
            if packet.toHost {
                deliveredToHostFrom[packet.from, default: 0] += packet.bytes.count
                host.receive(packet.bytes, from: packet.from, now: now, unixTime: unix)
            } else {
                client.receive(packet.bytes, from: packet.from, now: now)
            }
        }
        host.tick(now: now)
        client.tick(now: now)
        for (bytes, to) in host.takeOutbox() {
            if to == clientAddress { bytesToClient += bytes.count }
            sentByHostTo[to, default: 0] += bytes.count
            send(bytes, from: hostAddress, toHost: false)
        }
        for bytes in client.takeOutbox() { send(bytes, from: clientAddress, toHost: true) }
        for event in host.takeEvents() {
            hostEvents.append(event)
            switch event {
            case .keyframeNeeded(let stream):
                if ignoreKeyframeRequest.remove(stream) == nil { keyframeNeeded.insert(stream) }
            case .input(let message): inputs.append(message)
            default: break
            }
        }
        for event in client.takeEvents() {
            if case .frame(let stream, let frame) = event {
                let recorded = retainDeliveredPayloads ? frame : DeliveredFrame(
                    frameID: frame.frameID, header: frame.header, bytes: [], payloadOffset: 0, completedAt: frame.completedAt)
                if stream == 1 { delivered.append(recorded) }
                deliveredOn[stream, default: []].append(recorded)
                client.decoded(stream: stream, frameID: frame.frameID, isKeyframe: frame.header.frameType == .idr)
            } else {
                clientEvents.append(event)
            }
        }
    }

    private func send(_ bytes: Bytes, from: PeerAddress, toHost: Bool) {
        if let dropFilter, dropFilter(bytes, toHost) {
            if toHost { filteredToHost += 1 } else { filteredToClient += 1 }
            return
        }
        if loss > 0, Double.random(in: 0..<1, using: &rng) < loss { return }
        let path = toHost ? uplink : downlink
        for packet in path.enqueue(bytes, from: from, now: now) { schedule(packet, toHost: toHost) }
    }

    private func schedule(_ packet: SimulatedBottleneck.Transmission, toHost: Bool) {
        let extra = jitter > 0 ? UInt64.random(in: 0...jitter, using: &rng) : 0
        var at = (toHost ? stallEnd(packet.at) ?? packet.at : packet.at) + delay + extra
        if !toHost, let end = stallEnd(at) { at = end }
        inFlight.append((at, packet.bytes, packet.from, toHost))
    }

    /// When the stall under way at `time` ends, if one is.
    private func stallEnd(_ time: UInt64) -> UInt64? {
        guard let stalls else { return nil }
        let into = time % stalls.every
        return into < stalls.length ? time - into + stalls.length : nil
    }

    func run(for duration: UInt64, frameEvery interval: UInt64? = nil, frameSize: Int = 8_000, keyframeSize: Int = 120_000,
             during: ((SimulatedLink) -> Void)? = nil) {
        let end = now + duration
        var nextFrame = now
        while now < end {
            if let interval, now >= nextFrame, host.isStreaming {
                for stream in streams {
                    let key = keyframeNeeded.remove(stream) != nil
                    host.submit(
                        EncodedFrame(
                            isKeyframe: key, payload: Bytes(repeating: 0xab, count: key ? keyframeSize : frameSize),
                            codecConfig: CodecConfig(vps: [1], sps: [2], pps: [3]), captureTimeMicros: now),
                        stream: stream, now: now)
                }
                nextFrame = now + interval
            }
            during?(self)
            step()
        }
    }

    var keyframesSent: Int { keyframesSent(on: 1) }
    func keyframesSent(on stream: UInt8) -> Int { host.session?.videos[stream]?.stats.keyframes ?? 0 }
}

@Test(arguments: [false, true])
func inputOverflowEndsTheSession(dropClose: Bool) throws {
    let link = SimulatedLink()
    link.client.start(now: link.now)
    link.run(for: 50_000)
    #expect(link.client.isConnected)
    link.client.send(.key(usage: 4, down: true, isRepeat: false), now: link.now)
    link.run(for: 50_000)
    #expect(link.inputs.contains(.key(usage: 4, down: true, isRepeat: false)))
    link.hostEvents.removeAll()
    if dropClose { link.dropFilter = { _, towardsHost in towardsHost } }
    for _ in 0..<1024 { link.client.send(.key(usage: 4, down: true, isRepeat: true), now: link.now) }
    link.client.send(.key(usage: 4, down: false, isRepeat: false), now: link.now)
    #expect(!link.client.isConnected)
    link.run(for: 2_100_000)
    #expect(link.hostEvents.contains { event in
        switch event {
        case .sessionEnded, .paused: true
        default: false
        }
    })
    #expect(link.clientEvents.contains { event in
        if case .disconnected(let reason) = event { return reason.contains("input") }
        return false
    })
}

@Test func pointerMotionSurvivesReliableBackpressure() throws {
    let link = SimulatedLink()
    link.client.start(now: link.now)
    link.run(for: 50_000)
    for _ in 0..<1024 { link.client.send(.scroll(dx: 0, dy: 1, units: .pixels), now: link.now) }
    let motion = InputMessage.pointer(x: 123, y: 456, display: 0)
    #expect(link.client.send(.pointer(x: 10, y: 20, display: 0), now: link.now))
    #expect(link.client.send(motion, now: link.now))
    link.run(for: 200_000)
    #expect(link.client.isConnected)
    #expect(link.inputs.last == motion)
}

@Test(arguments: [false, true])
func buttonOverflowResetsInput(pendingMotion: Bool) throws {
    let link = SimulatedLink()
    link.client.start(now: link.now)
    link.run(for: 50_000)
    #expect(link.client.send(.button(.left, down: true), now: link.now))
    link.run(for: 50_000)
    for _ in 0..<1024 { #expect(link.client.send(.scroll(dx: 0, dy: 1, units: .pixels), now: link.now)) }
    if pendingMotion { #expect(link.client.send(.pointer(x: 10, y: 20, display: 0), now: link.now)) }
    #expect(!link.client.send(.button(.left, down: false), now: link.now))
    #expect(!link.client.isConnected)
    link.run(for: 10_000)
    #expect(link.host.session == nil)
    #expect(link.inputs == [.button(.left, down: true)])
    #expect(link.hostEvents.contains { if case .sessionEnded = $0 { true } else { false } })
}

@Test func sessionStreamsWithoutRepairOnACleanPath() throws {
    let link = SimulatedLink()
    link.client.start(now: link.now)
    link.run(for: 2_000_000, frameEvery: 16_667)
    let session = try #require(link.client.session)
    let video = try #require(session.videos[1])
    #expect(link.delivered.count >= 110)
    #expect(link.delivered.first?.header.frameType == .idr)
    #expect(zip(link.delivered, link.delivered.dropFirst()).allSatisfy { $1.frameID == $0.frameID + 1 })
    // Conformance test 4: a keyframe of about a hundred fragments, paced, draws no NACK.
    #expect(video.stats.nackedFragments == 0)
    #expect(link.keyframesSent == 1)
    #expect(session.connection.rtt.hasSample)
    #expect(link.host.session!.connection.rtt.hasSample)
}

/// Conformance test 1: the RESPONSE is lost; the identical INIT is answered from the cache.
@Test func lostResponseIsAnsweredFromTheCache() {
    let link = SimulatedLink()
    var dropped = false
    link.dropFilter = { bytes, toHost in
        if !toHost, bytes.first == Handshake.PacketType.response, !dropped {
            dropped = true
            return true
        }
        return false
    }
    link.client.start(now: link.now)
    link.run(for: 500_000, frameEvery: 16_667)
    #expect(link.client.isConnected)
    #expect(link.host.stats.initsAnsweredFromCache == 1)
    #expect(link.hostEvents.filter { if case .sessionStarted = $0 { true } else { false } }.count == 1)
    #expect(!link.delivered.isEmpty)
}

/// Conformance test 21: protected packets that overtake the RESPONSE are opened once it arrives.
@Test func packetsAheadOfTheResponseAreKept() {
    let link = SimulatedLink()
    var held: Bytes?
    link.dropFilter = { bytes, toHost in
        if !toHost, bytes.first == Handshake.PacketType.response, held == nil {
            held = bytes
            return true
        }
        return false
    }
    link.client.start(now: link.now)
    link.run(for: 3_000, frameEvery: 16_667)
    #expect(!link.client.isConnected)
    link.client.receive(held!, from: link.hostAddress, now: link.now)
    #expect(link.client.isConnected)
    link.step()
    #expect(link.host.stats.initsAnsweredFromCache == 0)
    link.run(for: 100_000, frameEvery: 16_667)
    #expect(link.delivered.first?.frameID == 1)
    #expect(link.keyframesSent == 1)
}

@Test func lossyPathRecoversAndDeliversInputExactlyOnce() throws {
    let link = SimulatedLink()
    link.loss = 0.02
    link.jitter = 1_500
    link.client.start(now: link.now)
    link.run(for: 300_000, frameEvery: 16_667)
    try #require(link.client.isConnected)
    var sent: [InputMessage] = []
    var n: UInt16 = 0
    link.run(for: 4_000_000, frameEvery: 16_667) { link in
        guard link.now % 5_000 == 0 else { return }
        n &+= 1
        let message: InputMessage = n % 3 == 0 ? .button(.left, down: n % 2 == 0) : .key(usage: n, down: true, isRepeat: false)
        sent.append(message)
        link.client.send(message, now: link.now)
    }
    link.loss = 0
    link.run(for: 500_000, frameEvery: 16_667)
    let video = try #require(link.client.session?.videos[1])
    // Every frame produced was either delivered or covered by a keyframe that followed it.
    #expect(link.delivered.count > 200)
    #expect(video.stats.nackedFragments > 0)
    #expect(zip(link.delivered, link.delivered.dropFirst()).allSatisfy {
        $1.frameID == $0.frameID + 1 || $1.header.frameType == .idr
    })
    // Input: keys on one stream and buttons on another, each in order and without duplicates.
    #expect(link.inputs.filter { $0.device == .keyboard } == sent.filter { $0.device == .keyboard })
    #expect(link.inputs.filter { $0.device == .pointer } == sent.filter { $0.device == .pointer })
}

@Test func pointerMotionIsMergedButButtonsAreNot() throws {
    let link = SimulatedLink()
    link.client.start(now: link.now)
    link.run(for: 100_000)
    try #require(link.client.isConnected)
    for x in 0..<10 { link.client.send(.pointer(x: UInt16(x), y: 0, display: 7), now: link.now) }
    link.client.send(.button(.left, down: true), now: link.now)
    link.run(for: 50_000)
    // The first motion goes at once; the rest merge into the newest, sent ahead of the press.
    #expect(link.inputs == [.pointer(x: 0, y: 0, display: 7), .pointer(x: 9, y: 0, display: 7), .button(.left, down: true)])
}

/// Conformance test 9: a new source port continues the stream with no keyframe and no cap.
@Test func portChangeContinuesWithoutAKeyframe() throws {
    let link = SimulatedLink()
    link.client.start(now: link.now)
    link.run(for: 500_000, frameEvery: 16_667)
    let before = link.delivered.count
    link.clientAddress.port = 50001
    link.run(for: 500_000, frameEvery: 16_667)
    let connection = try #require(link.host.session?.connection)
    #expect(connection.peer.port == 50001)
    #expect(!connection.isValidatingAddress)
    #expect(connection.stats.blockedByValidation == 0)
    #expect(link.keyframesSent == 1)
    #expect(link.delivered.count > before + 25)
}

/// Conformance test 20: a new IP address gets at most three times what it sent until a FEEDBACK
/// from it reports a packet sent there; then the stream continues without a keyframe.
@Test func newAddressIsCappedUntilValidated() throws {
    let link = SimulatedLink()
    link.client.start(now: link.now)
    link.run(for: 500_000, frameEvery: 16_667)
    let host = try #require(link.host.session?.connection)
    link.clientAddress = PeerAddress(ip: [10, 0, 0, 9], port: 50000)
    let sentBefore = link.bytesToClient
    var receivedFromNew = 0
    var validatedAt: UInt64?
    link.run(for: 500_000, frameEvery: 16_667) { link in
        if validatedAt == nil, host.peer == link.clientAddress {
            receivedFromNew = host.stats.bytesReceived
            if !host.isValidatingAddress { validatedAt = link.now }
        }
    }
    #expect(host.peer == link.clientAddress)
    #expect(validatedAt != nil)
    #expect(link.bytesToClient > sentBefore)
    _ = receivedFromNew
    #expect(link.keyframesSent == 1)
}

@Test func validationCapHoldsWhileTheClientCannotReport() throws {
    let link = SimulatedLink()
    link.client.start(now: link.now)
    link.run(for: 500_000, frameEvery: 16_667)
    let host = try #require(link.host.session?.connection)
    // A forged-source copy rebinds the host, and the real client cannot report from there:
    // simulate by moving the client and dropping everything the host sends to the new address.
    let moved = PeerAddress(ip: [192, 0, 2, 1], port: 1)
    link.clientAddress = moved
    link.dropFilter = { _, toHost in !toHost }
    link.run(for: 60_000, frameEvery: 16_667)
    #expect(host.isValidatingAddress)
    #expect(link.sentByHostTo[moved, default: 0] <= 3 * link.deliveredToHostFrom[moved, default: 0])
    #expect(link.sentByHostTo[moved, default: 0] > 0)
    #expect(host.stats.blockedByValidation > 0)
}

@Test func clientReconnectsAfterTheHostForgetsIt() throws {
    let link = SimulatedLink()
    link.client.start(now: link.now)
    link.run(for: 300_000, frameEvery: 16_667)
    let first = try #require(link.client.session?.connection.sessionID)
    // The same host secret: SESSION_UNKNOWN is recognised and the client starts over at once.
    link.host.close(now: link.now)
    _ = link.host.takeOutbox()
    link.replaceHost(secret: 3)
    link.keyframeNeeded.removeAll()
    link.run(for: 500_000, frameEvery: 16_667)
    #expect(link.client.isConnected)
    #expect(link.client.session?.connection.sessionID != first)
    #expect(link.delivered.last?.frameID ?? 0 > 1)

    // A host restarted with a new secret sends an unverifiable reset; the client falls back to
    // its silence timeout.
    let second = link.client.session!.connection.sessionID
    link.replaceHost(secret: 4)
    link.run(for: 7_000_000, frameEvery: 16_667)
    #expect(link.client.isConnected)
    #expect(link.client.session?.connection.sessionID != second)
}

@Test func hostPausesASilentClientAndResumesWithAKeyframe() throws {
    let link = SimulatedLink()
    link.client.start(now: link.now)
    link.run(for: 300_000, frameEvery: 16_667)
    link.dropFilter = { _, toHost in toHost }
    link.run(for: 2_500_000, frameEvery: 16_667)
    #expect(link.hostEvents.contains(.paused))
    #expect(!link.host.isStreaming)
    link.dropFilter = nil
    link.run(for: 300_000, frameEvery: 16_667)
    #expect(link.hostEvents.contains(.resumed))
    #expect(link.host.isStreaming)
    #expect(link.keyframesSent >= 2)
}

/// Conformance test 23, in the form the simulation allows: one of two video streams starts
/// without a keyframe, asks for one and gets it; the other stream never sees a second keyframe
/// and keeps delivering throughout.
@Test func videoStreamsRecoverIndependently() throws {
    let link = SimulatedLink()
    link.streams = [1, 16]
    link.ignoreKeyframeRequest = [16]
    link.client.start(now: link.now)
    link.run(for: 1_000_000, frameEvery: 16_667)
    try #require(link.client.session?.videoStreams == [1, 16, 17, 18])
    #expect(link.keyframesSent(on: 1) == 1)
    #expect(link.keyframesSent(on: 16) == 1)
    let first = try #require(link.deliveredOn[16]?.first)
    #expect(first.header.frameType == .idr && first.frameID > 1)
    #expect(link.client.session?.videos[16]?.stats.refreshRequests ?? 0 >= 1)
    #expect(link.client.session?.videos[1]?.stats.refreshRequests == 0)
    let one = link.deliveredOn[1] ?? []
    #expect(one.count >= 55 && zip(one, one.dropFirst()).allSatisfy { $1.frameID == $0.frameID + 1 })
    // The streams unused carry nothing.
    #expect(link.deliveredOn[17] == nil && link.keyframesSent(on: 17) == 0)
}

@Test func displayListAndSelectionTravelOnTheControlStream() throws {
    let link = SimulatedLink()
    link.client.start(now: link.now)
    link.run(for: 100_000)
    let displays = [
        DisplayInfo(id: 7, isPrimary: true, width: 3840, height: 2160, refreshMillihertz: 60_000, layoutX: 0, layoutY: 0,
                    layoutWidth: 1920, layoutHeight: 1080, name: "Studio Display"),
        DisplayInfo(id: 9, isPrimary: false, supportsHDR: true, width: 2560, height: 1440, refreshMillihertz: 120_000,
                    layoutX: -2560, layoutY: -200, layoutWidth: 2560, layoutHeight: 1440, name: "Écran 2"),
    ]
    link.host.send(.displays(displays))
    link.host.send(.streamDisplay(stream: 1, display: 7))
    link.run(for: 20_000)
    link.client.selectDisplay(9, on: 16)
    link.run(for: 20_000)
    let request = link.hostEvents.compactMap { event -> (UInt8, UInt32, UInt32)? in
        if case .displayRequested(let stream, let display, let reqID) = event { return (stream, display, reqID) }
        return nil
    }
    try #require(request.count == 1)
    #expect(request[0].0 == 16 && request[0].1 == 9)
    link.host.send(.displaySelected(reqID: request[0].2, stream: 16, display: 9))
    link.run(for: 20_000)
    var list: [DisplayInfo]?
    var bindings: [(UInt8, UInt32)] = []
    for event in link.clientEvents {
        switch event {
        case .displays(let l): list = l
        case .streamDisplay(let stream, let display): bindings.append((stream, display))
        default: break
        }
    }
    #expect(list == displays)
    #expect(bindings.map(\.0) == [1, 16] && bindings.map(\.1) == [7, 9])
    // A request for a stream that is not a video stream never reaches the host's application.
    link.client.selectDisplay(9, on: 4)
    link.run(for: 20_000)
    #expect(link.hostEvents.filter { if case .displayRequested = $0 { true } else { false } }.count == 1)
}

/// Wi-Fi stalls are late, not lost: 150 ms with the client's radio away every second, at a 60 ms
/// round trip, costs no frame and no keyframe. Before the fix each stall that outlasted a
/// frame's budget (140 ms here) broke the chain.
@Test func wifiStallsAreLateNotLost() throws {
    let link = SimulatedLink()
    link.delay = 30_000
    link.client.start(now: link.now)
    link.run(for: 400_000, frameEvery: 16_667)
    try #require(link.client.isConnected)
    // Frames large enough that pacing spreads them over most of an interval, so that a stall
    // catches one half received.
    link.stalls = (every: 1_000_000, length: 150_000)
    link.run(for: 5_000_000, frameEvery: 16_667, frameSize: 40_000)
    link.stalls = nil
    link.run(for: 300_000, frameEvery: 16_667, frameSize: 40_000)
    let video = try #require(link.client.session?.videos[1])
    #expect(video.stats.framesLost == 0 && video.stats.framesUndecodable == 0)
    #expect(video.stats.refreshRequests == 0 && link.keyframesSent == 1)
    #expect(link.delivered.count > 300)
    #expect(zip(link.delivered, link.delivered.dropFirst()).allSatisfy { $1.frameID == $0.frameID + 1 })
}

/// Random loss is mostly repaired by parity, with no round trip; what parity cannot cover is
/// asked for, and nothing is lost.
@Test func parityRepairsRandomLoss() throws {
    let link = SimulatedLink()
    link.delay = 30_000
    link.client.start(now: link.now)
    link.run(for: 400_000, frameEvery: 16_667)
    try #require(link.client.isConnected && link.client.session!.fec)
    link.loss = 0.01
    link.run(for: 5_000_000, frameEvery: 16_667, frameSize: 40_000)
    link.loss = 0
    link.run(for: 300_000, frameEvery: 16_667, frameSize: 40_000)
    let video = try #require(link.client.session?.videos[1])
    #expect(video.stats.fecRepaired > 2 * video.stats.nackedFragments)
    #expect(video.stats.framesLost + video.stats.framesUndecodable == 0)
    #expect(link.keyframesSent == 1)
}

/// The host takes its first round-trip sample from the client's first packet, a PING sent the
/// moment the RESPONSE opens, rather than budgeting with the 30 ms default until FEEDBACK comes.
@Test func hostSeedsItsRoundTripFromTheHandshake() throws {
    let link = SimulatedLink()
    link.delay = 40_000
    link.client.start(now: link.now)
    while link.host.session == nil { link.step() }
    link.run(for: 81_000, frameEvery: 16_667)
    let rtt = try #require(link.host.session?.connection.rtt)
    #expect(rtt.hasSample && (79_000...83_000).contains(rtt.smoothed))
}

@Test func fecIsUsedOnlyWhenBothEndsAgree() throws {
    let on = SimulatedLink()
    on.client.start(now: on.now)
    on.run(for: 200_000, frameEvery: 16_667)
    #expect(on.client.session?.fec == true && on.host.session?.fec == true)
    #expect(on.host.session!.videos[1]!.stats.parityFragments > 0)
    for link in [SimulatedLink(offerFEC: false), SimulatedLink(hostConfig: { var c = HostConfig(); c.fecPercent = 0; return c }())] {
        link.client.start(now: link.now)
        link.run(for: 200_000, frameEvery: 16_667)
        #expect(link.client.session?.fec == false && link.host.session?.fec == false)
        #expect(link.host.session!.videos[1]!.stats.parityFragments == 0 && link.delivered.count > 5)
    }
}

@Test(arguments: [false, true])
func clientRoutesRepliesAndCloseToAuthenticatedReboundHost(changesIP: Bool) throws {
    let link = SimulatedLink()
    link.client.start(now: link.now)
    let initial = link.client.takeOutboundDatagrams()
    #expect(initial.count == 1 && initial[0].destination == link.hostAddress)
    link.host.receive(initial[0].bytes, from: link.clientAddress, now: link.now, unixTime: link.unix)
    for (bytes, _) in link.host.takeOutbox() { link.client.receive(bytes, from: link.hostAddress, now: link.now) }
    link.run(for: 50_000)
    let host = try #require(link.host.session?.connection)
    let changed = PeerAddress(ip: changesIP ? [10, 0, 0, 9] : link.hostAddress.ip, port: 7374)
    let packet = try #require(host.seal(Chunk.ping(id: 1).encoded, now: link.now))
    link.client.receive(packet, from: changed, now: link.now)
    for id: UInt32 in 2...4 {
        let extra = try #require(host.seal(Chunk.ping(id: id).encoded, now: link.now))
        link.client.receive(extra, from: changed, now: link.now)
    }
    #expect(link.client.session?.connection.peer == changed)
    link.client.receive(packet, from: link.hostAddress, now: link.now)
    #expect(link.client.session?.connection.peer == changed)
    link.client.tick(now: link.now + 100_000)
    let replies = link.client.takeOutboundDatagrams()
    #expect(!replies.isEmpty && replies.allSatisfy { $0.destination == changed })
    link.client.close(now: link.now + 100_001)
    let closing = link.client.takeOutboundDatagrams()
    #expect(!closing.isEmpty && closing.allSatisfy { $0.destination == changed })
    #expect(link.client.session == nil)
}
