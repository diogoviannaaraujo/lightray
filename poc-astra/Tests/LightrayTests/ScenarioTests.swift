import Foundation
import LightrayCrypto
import LightraySession
import LightrayTestSupport
import Testing

final class Pair {
    let host: Connection
    let client: Connection
    var now = Instant()
    var hostAddress = PeerAddress(port: 47000), clientAddress = PeerAddress(port: 47001)
    let network: SimulatedNetwork
    var received: [(UInt32, FrameInfo)] = []
    var hostEvents: [ConnectionEvent] = []
    var clientEvents: [ConnectionEvent] = []
    init(model: LinkModel = .init(), policy: SessionPolicy = .init(), ltr: Bool = true) throws {
        let psk = [UInt8](repeating: 3, count: 32)
        let initiator = try HandshakeInitiator(pairingID: 1, psk: psk)
        let responder = try HandshakeResponder(secret: .init(repeating: 4, count: 32))
        let initial = try initiator.start(configuration: .init(), timestamp: 100, ltr: ltr)
        let response = try responder.accept(initial, psk: psk, sessionID: 1, timestamp: 100)
        host = Connection(result: try #require(response.result), role: .host, peer: clientAddress, at: now, policy: policy)
        client = Connection(result: try initiator.finish(response.packet), role: .client, peer: hostAddress, at: now, policy: policy)
        network = SimulatedNetwork(seed: 74, model: model)
    }
    func advance(_ ns: UInt64) throws {
        let target = now.advanced(by: ns)
        while now < target {
            now = .init(min(target.nanoseconds, now.nanoseconds + 1_000_000))
            host.handleTimeout(at: now)
            client.handleTimeout(at: now)
            while let packet = host.pollTransmit(at: now) { network.send(packet, from: hostAddress, at: now) }
            while let packet = client.pollTransmit(at: now) { network.send(packet, from: clientAddress, at: now) }
            network.deliver(at: now) { packet, from in if packet.peer == hostAddress { host.handle(datagram: packet.bytes, from: from, at: now) } else if packet.peer == clientAddress { client.handle(datagram: packet.bytes, from: from, at: now) } }
            while let event = host.pollEvent() { hostEvents.append(event) }
            while let event = client.pollEvent() {
                if case .frame(let frame, let info) = event {
                    received.append((frame.frameID, info))
                    try client.reportDecoded(stream: frame.stream, frameID: frame.frameID, at: now)
                } else {
                    clientEvents.append(event)
                }
            }
        }
    }
    func frame(idr: Bool = false, bytes: Int = 41_666) throws { try host.submit(.init(stream: 1, storage: FrameBytes(SyntheticFrames.bytes(count: bytes)), info: SyntheticFrames.info(idr: idr, captureTime: now.microseconds)), at: now) }
}
@Test func cleanLinkFramesAndNoNacks() throws {
    let pair = try Pair()
    for i in 0..<120 {
        try pair.frame(idr: i == 0)
        try pair.advance(16_666_667)
    }
    try pair.advance(100_000_000)
    #expect(pair.received.count == 120)
    #expect(pair.client.stats.streams.nacks == 0)
    #expect(pair.host.stats.path.malformed == 0)
    #expect(pair.client.stats.path.malformed == 0)
}
@Test func randomLossRecoveryAndReliableOrdering() throws {
    var model = LinkModel()
    model.loss = 0.02
    let pair = try Pair(model: model)
    for i in 0..<120 {
        try pair.frame(idr: i == 0)
        try pair.client.sendReliable(stream: 5, bytes: [UInt8(i)], at: pair.now)
        try pair.advance(16_666_667)
    }
    try pair.advance(500_000_000)
    let reliable = pair.hostEvents.compactMap { event -> [UInt8]? in
        if case .reliable(5, let data) = event { return data }
        return nil
    }
    #expect(pair.received.count == 120)
    #expect(reliable == (0..<120).map { [UInt8($0)] })
    #expect(pair.client.stats.streams.nacks > 0)
}
@Test func parkTwentySecondsRebindAndIDRResume() throws {
    let pair = try Pair()
    try pair.frame(idr: true)
    try pair.advance(30_000_000)
    try pair.client.park(at: pair.now)
    try pair.advance(10_000_000)
    #expect(pair.host.state == .parked)
    #expect(pair.host.retainedMediaBytes == 0)
    try pair.advance(20_000_000_000)
    pair.clientAddress.port = 47002
    try pair.client.resume(at: pair.now)
    try pair.advance(30_000_000)
    #expect(pair.host.state == .active)
    #expect(pair.host.peer.port == 47002)
    #expect(pair.hostEvents.contains { if case .refreshRequired(1, .idr, _) = $0 { true } else { false } })
    try pair.frame(idr: false)
    try pair.advance(30_000_000)
    #expect(pair.received.count == 1)
    try pair.frame(idr: true)
    try pair.advance(30_000_000)
    #expect(pair.received.count == 2)
    #expect(pair.client.stats.reconnect.resumeLatency.count == 1)
}
@Test func silentParkingIdleExpiry() throws {
    var policy = SessionPolicy()
    policy.parkAfterSilence = 10_000_000
    policy.pipelineIdleAfter = 20_000_000
    policy.graceWindow = 50_000_000
    let pair = try Pair(policy: policy)
    pair.host.handleTimeout(at: .init(10_000_000))
    #expect(pair.host.state == .parked)
    #expect(pair.host.nextTimeout() == nil)
    #expect(pair.host.retainedMediaBytes == 0)
    pair.host.sweepParked(at: .init(30_000_000))
    var events: [ConnectionEvent] = []
    while let event = pair.host.pollEvent() { events.append(event) }
    #expect(events.contains { if case .idle = $0 { true } else { false } })
    pair.host.sweepParked(at: .init(60_000_000))
    #expect(pair.host.state == .closed)
}
@Test func oldAuthenticatedPacketCannotRebindAndNATNeedsNoIDR() throws {
    let pair = try Pair()
    try pair.client.sendDatagram(stream: 6, bytes: [1], at: pair.now)
    let old = try #require(pair.client.pollTransmit(at: pair.now))
    try pair.client.sendDatagram(stream: 6, bytes: [2], at: pair.now)
    let fresh = try #require(pair.client.pollTransmit(at: pair.now))
    pair.host.handle(datagram: fresh.bytes, from: pair.clientAddress, at: .init(1))
    pair.host.handle(datagram: old.bytes, from: .init(port: 49999), at: .init(2))
    #expect(pair.host.peer == pair.clientAddress)
    try pair.client.sendDatagram(stream: 6, bytes: [3], at: pair.now)
    let newest = try #require(pair.client.pollTransmit(at: pair.now))
    pair.host.handle(datagram: newest.bytes, from: .init(port: 49998), at: .init(3))
    #expect(pair.host.peer.port == 49998)
    var refresh = false
    while let event = pair.host.pollEvent() { if case .refreshRequired = event { refresh = true } }
    #expect(!refresh)
}
@Test func reconfigureRoundTrip() throws {
    let pair = try Pair()
    var config = Configuration()
    config.bitrate = 12_000_000
    config.maxDatagramSize = 1400
    try pair.client.reconfigure(config, at: pair.now)
    try pair.advance(100_000_000)
    #expect(pair.host.configuration.bitrate == 12_000_000)
    #expect(pair.client.configuration == pair.host.configuration)
    #expect(pair.client.configuration.generation == 1)
}
@Test func sixtySeconds1080p60AndBoundedLTRAcks() throws {
    let pair = try Pair()
    for i in 0..<3600 {
        try pair.frame(idr: i == 0)
        try pair.advance(16_666_667)
    }
    try pair.advance(100_000_000)
    #expect(pair.received.count == 3600)
    #expect(pair.client.stats.streams.nacks == 0)
    #expect(!pair.host.stats.backstop)
    #expect(pair.client.stats.streams.frameAcksSent <= 241)
    #expect(pair.client.stats.streams.frameAcksSent >= 220)
    #expect(pair.host.retainedLTRAcknowledgments(stream: 1) <= 16)
}
@Test func burstLossRequestsLTRAndIDRFallback() throws {
    for useLTR in [true, false] {
        let pair = try Pair(ltr: useLTR)
        try pair.frame(idr: true)
        try pair.advance(30_000_000)
        if !useLTR { try pair.client.decoderReset(stream: 1, at: pair.now) }
        pair.network.model.blackout = pair.now.nanoseconds..<(pair.now.nanoseconds + 30_000_000)
        try pair.frame()
        try pair.advance(16_666_667)
        try pair.frame()
        try pair.advance(100_000_000)
        // Simulate decoder failure after the retransmission deadline to exercise refresh escalation.
        if useLTR {
            let info = FrameInfo(reference: .ltrAny)
            try pair.host.submit(.init(stream: 1, storage: FrameBytes([1, 2, 3]), info: info), at: pair.now)
            try pair.advance(30_000_000)
            #expect(pair.received.last?.1.reference == .ltrAny)
        } else {
            #expect(pair.hostEvents.contains { if case .refreshRequired(1, .idr, _) = $0 { true } else { false } })
            try pair.frame(idr: true)
            try pair.advance(30_000_000)
            #expect(pair.received.last?.1.type == .idr)
        }
    }
}
@Test func bidirectionalReliableAtFivePercentLoss() throws {
    var model = LinkModel()
    model.loss = 0.05
    model.reorder = 0.02
    let pair = try Pair(model: model)
    for i in 0..<100 {
        try pair.host.sendReliable(stream: 5, bytes: [UInt8](repeating: UInt8(i), count: 3000), at: pair.now)
        try pair.client.sendReliable(stream: 5, bytes: [UInt8(i)], at: pair.now)
        try pair.frame(idr: i == 0, bytes: 10_000)
        try pair.advance(16_666_667)
    }
    try pair.advance(1_000_000_000)
    let hostReceived = pair.hostEvents.compactMap { if case .reliable(5, let bytes) = $0 { bytes.first } else { nil } }
    let clientReceived = pair.clientEvents.compactMap { if case .reliable(5, let bytes) = $0 { bytes.first } else { nil } }
    #expect(hostReceived == (0..<100).map(UInt8.init))
    #expect(clientReceived == (0..<100).map(UInt8.init))
}
@Test func bottleneckEngagesLossBackstop() throws {
    var model = LinkModel()
    model.bitsPerSecond = 30_000_000
    model.queueBytes = 40_000
    let pair = try Pair(model: model)
    var config = Configuration()
    config.bitrate = 50_000_000
    try pair.client.reconfigure(config, at: pair.now)
    try pair.advance(50_000_000)
    for i in 0..<210 {
        try pair.frame(idr: i % 60 == 0, bytes: 104_166)
        try pair.advance(16_666_667)
    }
    try pair.advance(100_000_000)
    #expect(pair.network.dropped > 0)
    #expect(pair.host.stats.backstop)
    #expect(pair.client.stats.backstop)
    #expect(pair.client.stats.path.queuingDelay > 0)
}
@Test func expiredLossEscalatesToLTRAndDecoderResetForcesIDR() throws {
    let pair = try Pair()
    try pair.frame(idr: true)
    try pair.advance(30_000_000)
    // Drop a frame without allowing the sender to answer the receiver's NACKs.
    try pair.frame()
    while pair.host.pollTransmit(at: pair.now) != nil {}
    try pair.frame()
    while let packet = pair.host.pollTransmit(at: pair.now) { pair.client.handle(datagram: packet.bytes, from: pair.hostAddress, at: pair.now) }
    for step in 1...60 {
        pair.client.handleTimeout(at: pair.now.advanced(by: UInt64(step) * 1_000_000))
        while let packet = pair.client.pollTransmit(at: pair.now.advanced(by: UInt64(step) * 1_000_000)) { if step >= 50 { pair.host.handle(datagram: packet.bytes, from: pair.clientAddress, at: pair.now.advanced(by: UInt64(step) * 1_000_000)) } }
    }
    var sawLTR = false
    while let event = pair.host.pollEvent() { if case .refreshRequired(1, .ltr, let acks) = event { sawLTR = !acks.isEmpty } }
    #expect(sawLTR)
    try pair.client.decoderReset(stream: 1, at: pair.now.advanced(by: 70_000_000))
    while let packet = pair.client.pollTransmit(at: pair.now.advanced(by: 70_000_000)) { pair.host.handle(datagram: packet.bytes, from: pair.clientAddress, at: pair.now.advanced(by: 70_000_000)) }
    var sawIDR = false
    while let event = pair.host.pollEvent() { if case .refreshRequired(1, .idr, _) = event { sawIDR = true } }
    #expect(sawIDR)
}
@Test func sixtySecondsRandomLossMeetsCompletionTarget() throws {
    var model = LinkModel()
    model.loss = 0.02
    let pair = try Pair(model: model)
    for i in 0..<3600 {
        try pair.frame(idr: i == 0)
        try pair.advance(16_666_667)
    }
    try pair.advance(100_000_000)
    #expect(Double(pair.received.count) / 3600 >= 0.999)
}
@Test func pacerBoundsLargeIDRBottleneckQueue() throws {
    var model = LinkModel()
    model.bitsPerSecond = 240_000_000
    model.queueBytes = 1_000_000
    model.delay = 0
    let unpaced = SimulatedNetwork(model: model)
    let paced = SimulatedNetwork(model: model)
    let pacer = Pacer(maxBurstBytes: 24_000)
    pacer.bytesPerSecond = 30_000_000
    let payload = [UInt8](repeating: 0, count: 1149)
    let destination = PeerAddress(port: 1)
    let source = PeerAddress(port: 2)
    for _ in 0..<436 {
        let packet = Transmit(bytes: payload, peer: destination)
        unpaced.send(packet, from: source, at: .init())
        try pacer.enqueue(payload, priority: .video, at: .init())
    }
    for millisecond in 0..<30 {
        let now = Instant(UInt64(millisecond) * 1_000_000)
        while let bytes = pacer.poll(at: now) { paced.send(.init(bytes: bytes, peer: destination), from: source, at: now) }
    }
    #expect(paced.peakQueuedBytes < unpaced.peakQueuedBytes / 4)
    #expect(pacer.queuedBytes == 0)
}
@Test func endpointExpiryResetAndNewHandshake() throws {
    var policy = SessionPolicy()
    policy.parkAfterSilence = 10_000_000
    policy.pipelineIdleAfter = 20_000_000
    policy.graceWindow = 30_000_000
    let psk = [UInt8](repeating: 3, count: 32)
    let host = try HostEndpoint(pairings: [1: psk], secret: .init(repeating: 4, count: 32), policy: policy)
    let hostAddress = PeerAddress(port: 47000)
    let clientAddress = PeerAddress(port: 47001)
    let client = ClientEndpoint(peer: hostAddress, pairingID: 1, psk: psk)
    try client.connect(at: .init(), timestamp: 100)
    let initial = try #require(client.pollTransmit(at: .init()))
    host.handle(datagram: initial.bytes, from: clientAddress, at: .init(), timestamp: 100)
    let response = try #require(host.pollTransmit(at: .init()))
    client.handle(datagram: response.bytes, from: hostAddress, at: .init())
    let connection = try #require(client.connection)
    let oldID = connection.sessionID
    host.handleTimeout(at: .init(10_000_000))
    host.handleTimeout(at: .init(100_000_000))
    #expect(host.connections.isEmpty)
    try connection.sendDatagram(stream: 6, bytes: [1], at: .init(100_000_000))
    let packet = try #require(connection.pollTransmit(at: .init(100_000_000)))
    host.handle(datagram: packet.bytes, from: clientAddress, at: .init(100_000_000), timestamp: 100)
    let reset = try #require(host.pollTransmit(at: .init(100_000_000)))
    #expect(reset.bytes.count == 21)
    var forged = reset.bytes
    forged[20] ^= 1
    client.handle(datagram: forged, from: hostAddress, at: .init(100_000_000))
    #expect(connection.state == .active)
    client.handle(datagram: reset.bytes, from: hostAddress, at: .init(100_000_000))
    #expect(connection.state == .closed)
    try client.connect(at: .init(200_000_000), timestamp: 100)
    let again = try #require(client.pollTransmit(at: .init(200_000_000)))
    host.handle(datagram: again.bytes, from: clientAddress, at: .init(200_000_000), timestamp: 100)
    let accepted = try #require(host.pollTransmit(at: .init(200_000_000)))
    client.handle(datagram: accepted.bytes, from: hostAddress, at: .init(200_000_000))
    #expect(client.connection?.sessionID != oldID)
}
@Test func invalidReconfigureReturnsExplicitRejection() throws {
    let pair = try Pair()
    var message = ByteWriter()
    message.put(UInt8(1))
    message.put(UInt32(77))
    message.put(UInt8(1))
    message.bytes += Configuration().encode()
    try pair.client.sendReliable(stream: 0, bytes: message.bytes, at: pair.now)
    try pair.advance(50_000_000)
    #expect(pair.clientEvents.contains { if case .reconfigureRejected(77) = $0 { true } else { false } })
    #expect(pair.host.configuration.generation == 0)
}
@Test func submittedStorageRetainedUntilParking() throws {
    let pair = try Pair()
    weak var observed: FrameBytes?
    do {
        let bytes = FrameBytes([1, 2, 3])
        observed = bytes
        try pair.host.submit(.init(stream: 1, storage: bytes, info: SyntheticFrames.info(idr: true)), at: pair.now)
    }
    #expect(observed != nil)
    try pair.host.park(at: pair.now)
    #expect(observed == nil)
    #expect(pair.host.retainedMediaBytes == 0)
}
