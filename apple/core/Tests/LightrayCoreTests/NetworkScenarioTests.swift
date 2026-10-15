import Testing

@testable import LightrayCore

private struct NetworkScenario: Sendable, CustomStringConvertible {
    let fec: Bool
    let streamCount: Int
    let seed: UInt64

    static let all = [false, true].flatMap { fec in
        [1, 4].flatMap { count in [UInt64(1), 42, 999].map { NetworkScenario(fec: fec, streamCount: count, seed: $0) } }
    }

    var description: String { "FEC=\(fec), streams=\(streamCount), seed=\(seed)" }

    func makeLink() -> SimulatedLink {
        let link = SimulatedLink(offerFEC: fec, videoStreamCount: streamCount, seed: seed)
        link.streams = streamCount == 1 ? [1] : [1, 16, 17, 18]
        link.retainDeliveredPayloads = false
        link.delay = seed == 42 ? 30_000 : seed == 999 ? 15_000 : 2_000
        link.jitter = 1_500
        link.downlink.bitrate = 100_000_000 * streamCount
        link.downlink.queueLimitBytes = (64 << 10) * streamCount
        link.uplink.bitrate = 1_000_000
        link.uplink.queueLimitBytes = 16 << 10
        return link
    }
}

private func expectOrderedVideo(_ link: SimulatedLink) {
    for stream in link.streams {
        let frames = link.deliveredOn[stream, default: []]
        #expect(frames.first?.header.frameType == .idr)
        #expect(Set(frames.map(\.frameID)).count == frames.count)
        #expect(zip(frames, frames.dropFirst()).allSatisfy {
            $1.frameID > $0.frameID && ($1.frameID == $0.frameID + 1 || $1.header.frameType == .idr)
        })
    }
}

private func expectInputs(_ link: SimulatedLink, _ sent: [InputMessage]) {
    // Independent reliable streams preserve their own ordering, rather than a global order.
    for device in [InputMessage.Device.keyboard, .pointer] {
        #expect(link.inputs.filter { $0.device == device } == sent.filter { $0.device == device })
    }
}

private func expectFreshVideo(_ link: SimulatedLink, since restoredAt: UInt64, countsBefore: [UInt8: Int]) throws {
    for stream in link.streams {
        let frames = link.deliveredOn[stream, default: []]
        #expect(frames.count >= countsBefore[stream, default: 0] + 30)
        let latest = try #require(frames.last)
        #expect(UInt64(latest.header.captureTimeMicros) > restoredAt)
        #expect(link.now - UInt64(latest.header.captureTimeMicros) < 150_000)
    }
    expectOrderedVideo(link)
}

@Test func bottleneckSerializesPacketsAndDropsOverflow() {
    let path = SimulatedBottleneck()
    let peer = PeerAddress(ip: [127, 0, 0, 1], port: 7373)
    path.bitrate = 8_000_000 // One byte per microsecond.
    path.queueLimitBytes = 2_000
    #expect(path.enqueue(Bytes(repeating: 1, count: 1_000), from: peer, now: 0).isEmpty)
    #expect(path.enqueue(Bytes(repeating: 2, count: 1_000), from: peer, now: 0).isEmpty)
    #expect(path.enqueue([3], from: peer, now: 0).isEmpty)
    #expect(path.droppedDatagrams == 1 && path.peakQueuedBytes == 2_000)
    #expect(path.advance(to: 999).isEmpty)
    let first = path.advance(to: 1_000)
    #expect(first.map(\.at) == [1_000] && first.first?.bytes.first == 1)
    #expect(path.queuedBytes == 1_000)
    let second = path.advance(to: 2_000)
    #expect(second.map(\.at) == [2_000] && second.first?.bytes.first == 2)
    #expect(path.queuedBytes == 0 && path.transmittedBytes == 2_000)
    // An idle link accumulates no credit for a subsequent burst.
    #expect(path.advance(to: 1_000_000).isEmpty)
    #expect(path.enqueue([4], from: peer, now: 1_000_000).isEmpty)
    #expect(path.advance(to: 1_000_000).isEmpty)
    #expect(path.advance(to: 1_000_001).map(\.at) == [1_000_001])
}

@Test func bottleneckCapacityChangesAffectQueuedPackets() {
    let path = SimulatedBottleneck()
    let peer = PeerAddress(ip: [127, 0, 0, 1], port: 7373)
    path.bitrate = 8_000_000
    #expect(path.enqueue(Bytes(repeating: 1, count: 1_000), from: peer, now: 0).isEmpty)
    #expect(path.advance(to: 500).isEmpty)
    path.bitrate = 0
    #expect(path.advance(to: 10_500).isEmpty && path.queuedBytes == 1_000)
    path.bitrate = 16_000_000
    #expect(path.advance(to: 10_749).isEmpty)
    #expect(path.advance(to: 10_750).map(\.at) == [10_750])
    #expect(path.longestQueueMicros == 10_750 && path.queuedBytes == 0)
}

/// A fixed-bitrate sender may lose video under sustained overload, but input must continue and
/// every stream must recover when capacity returns. Histories retain no media reservations.
@Test(arguments: NetworkScenario.all)
private func bandwidthDropBoundsQueuesAndRecovers(scenario: NetworkScenario) throws {
    let link = scenario.makeLink()
    link.client.start(now: link.now)
    link.run(for: 500_000, frameEvery: 16_667, frameSize: 16_000)
    let clientSession = try #require(link.client.session)
    let hostSession = try #require(link.host.session)
    for stream in link.streams { try #require(link.deliveredOn[stream, default: []].count >= 10) }

    link.downlink.bitrate = 2_000_000 * scenario.streamCount
    var sent: [InputMessage] = []
    var nextInput = link.now
    link.run(for: 2_000_000, frameEvery: 16_667, frameSize: 16_000) { link in
        guard link.now >= nextInput else { return }
        nextInput += 50_000
        for message in [InputMessage.key(usage: 4, down: true, isRepeat: false), .key(usage: 4, down: false, isRepeat: false),
                        .button(.left, down: true), .button(.left, down: false)] {
            #expect(link.client.send(message, now: link.now))
            sent.append(message)
        }
    }
    #expect(link.downlink.droppedDatagrams > 0)
    #expect(link.downlink.longestQueueMicros > 150_000)
    #expect(link.downlink.peakQueuedBytes <= link.downlink.queueLimitBytes)
    #expect(link.uplink.droppedDatagrams == 0)
    #expect(link.inputs.count >= sent.count - 4)
    #expect(link.client.session === clientSession && link.host.session === hostSession)
    #expect(clientSession.videos.values.contains { $0.stats.framesLost > 0 })
    #expect(clientSession.connection.memoryBudget.peakBytes < 16 << 20)
    #expect(hostSession.connection.memoryBudget.peakBytes < 1 << 20)
    for video in clientSession.videos.values { #expect(video.memoryBudget.peakBytes < 8 << 20) }

    let restoredAt = link.now
    let counts = link.deliveredOn.mapValues(\.count)
    link.downlink.bitrate = 100_000_000 * scenario.streamCount
    link.run(for: 1_500_000, frameEvery: 16_667, frameSize: 16_000)
    try expectFreshVideo(link, since: restoredAt, countsBefore: counts)
    expectInputs(link, sent)
    #expect(link.client.session === clientSession && link.host.session === hostSession)
    let drops = link.downlink.droppedDatagrams
    link.run(for: 500_000, frameEvery: 16_667, frameSize: 16_000)
    #expect(link.downlink.droppedDatagrams == drops)
    link.run(for: 750_000)
    #expect(link.downlink.queuedBytes == 0 && link.uplink.queuedBytes == 0)
    #expect(hostSession.videos.values.allSatisfy { !$0.hasBacklog })
    #expect(clientSession.connection.memoryBudget.usedBytes == 0)
}

/// A consecutive burst exceeds the parity available to a frame; NACKs repair it before its
/// deadline. The other streams keep their prediction chains, with FEC both enabled and disabled.
@Test(arguments: NetworkScenario.all)
private func burstBeyondParityIsRetransmitted(scenario: NetworkScenario) throws {
    let link = scenario.makeLink()
    link.client.start(now: link.now)
    link.run(for: 500_000, frameEvery: 16_667, frameSize: 40_000)
    try #require(link.client.isConnected)
    let burstSize = 12 * scenario.streamCount + Int(scenario.seed % 3)
    var remaining = burstSize
    link.dropFilter = { bytes, toHost in
        guard !toHost, ProtectedHeader(bytes) != nil, remaining > 0 else { return false }
        remaining -= 1
        return true
    }
    let counts = link.deliveredOn.mapValues(\.count)
    let burstAt = link.now
    link.run(for: 1_000_000, frameEvery: 16_667, frameSize: 40_000)
    #expect(remaining == 0 && link.filteredToClient == burstSize)
    let client = try #require(link.client.session)
    let host = try #require(link.host.session)
    #expect(client.videos.values.reduce(0) { $0 + $1.stats.nackedFragments } > 0)
    #expect(host.videos.values.reduce(0) { $0 + $1.stats.retransmissions } > 0)
    for stream in link.streams {
        #expect(client.videos[stream]?.stats.framesLost == 0)
        #expect(client.videos[stream]?.stats.framesUndecodable == 0)
        #expect(client.videos[stream]?.stats.refreshRequests == 0)
        #expect(link.keyframesSent(on: stream) == 1)
    }
    try expectFreshVideo(link, since: burstAt, countsBefore: counts)
}

/// Lose traffic longer than the retention/deadline allowance, then lose the first recovery IDR
/// for equally long. Recovery must use another request identifier and eventually stop retrying.
@Test(arguments: NetworkScenario.all)
private func lostRecoveryIDRStartsANewAttempt(scenario: NetworkScenario) throws {
    let link = scenario.makeLink()
    link.client.start(now: link.now)
    link.run(for: 500_000, frameEvery: 16_667)
    let sessionID = try #require(link.client.session?.connection.sessionID)
    let counts = link.deliveredOn.mapValues(\.count)
    let burstEnd = link.now + 650_000
    var recoveryDropEnd: UInt64?
    link.dropFilter = { [unowned link] _, toHost in
        guard !toHost else { return false }
        if link.now < burstEnd { return true }
        if recoveryDropEnd == nil, link.streams.contains(where: { link.keyframesSent(on: $0) > 1 }) {
            recoveryDropEnd = link.now + 650_000
        }
        return recoveryDropEnd.map { link.now < $0 } ?? false
    }
    link.run(for: 4_000_000, frameEvery: 16_667)
    let restoredAt = try #require(recoveryDropEnd)
    #expect(link.now > restoredAt && link.filteredToClient > 100)
    #expect(link.client.session?.connection.sessionID == sessionID)
    try expectFreshVideo(link, since: restoredAt, countsBefore: counts)
    let host = try #require(link.host.session)
    let client = try #require(link.client.session)
    for stream in link.streams {
        // VideoSender counts only distinct request identifiers, not repetitions of one attempt.
        #expect(host.videos[stream]!.stats.refreshRequests >= 2)
        #expect(client.videos[stream]!.stats.framesLost > 0)
        #expect((3...20).contains(link.keyframesSent(on: stream)))
    }
    let requests = client.videos.mapValues { $0.stats.refreshRequests }
    let keyframes = host.videos.mapValues { $0.stats.keyframes }
    link.run(for: 500_000, frameEvery: 16_667)
    #expect(client.videos.mapValues { $0.stats.refreshRequests } == requests)
    #expect(host.videos.mapValues { $0.stats.keyframes } == keyframes)
}

private enum FailedDirection: Sendable { case uplink, downlink }

/// Known traffic keys let these transport tests lose particular authenticated chunks without
/// exposing an endpoint's private keys. Packets still pass through Connection's replay checks,
/// feedback/RTT machinery and reliable streams, and through the real media sender and receiver.
private final class InspectableTransport {
    let host: Connection
    let client: Connection
    let senders: [UInt8: VideoSender]
    let receivers: [UInt8: VideoReceiver]
    private(set) var now: UInt64 = 10_000_000
    var dropFilter: (([Chunk], Bool) -> Bool)?
    private(set) var messagesAtHost: [UInt8: [Bytes]] = [:]
    private(set) var messagesAtClient: [UInt8: [Bytes]] = [:]
    private(set) var frames: [UInt8: [UInt32]] = [:]
    private(set) var refreshRequests = 0
    private let hostAddress = PeerAddress(ip: [10, 0, 0, 1], port: 7373)
    private let clientAddress = PeerAddress(ip: [10, 0, 0, 2], port: 50000)
    private let hostKey = Bytes(repeating: 9, count: 32)
    private let clientKey = Bytes(repeating: 7, count: 32)
    private var rng: SplitMix
    private var inFlight: [(at: UInt64, bytes: Bytes, toHost: Bool)] = []

    init(scenario: NetworkScenario) {
        rng = SplitMix(state: scenario.seed)
        let config = ClientConfig(pairingID: 42, psk: clientKey, host: hostAddress)
        var entries = config.streams.entries
        if scenario.streamCount == 1 { entries.removeAll { $0.kind == .video && $0.id != 1 } }
        let table = StreamTable(entries)
        host = Connection(role: .host, sessionID: 1, sendKey: hostKey, receiveKey: clientKey,
                          streams: table, maxDatagramSize: 1200, peer: clientAddress, now: now)
        client = Connection(role: .client, sessionID: 1, sendKey: clientKey, receiveKey: hostKey,
                            streams: table, maxDatagramSize: 1200, peer: hostAddress, now: now)
        host.rtt.add(4_000)
        client.rtt.add(4_000)
        let videos = entries.filter { $0.kind == .video }
        senders = Dictionary(uniqueKeysWithValues: videos.map { entry in
            let sender = VideoSender(stream: entry.id, bitrate: 20_000_000, frameRate: 60)
            sender.fecPercent = scenario.fec ? 10 : 0
            return (entry.id, sender)
        })
        receivers = Dictionary(uniqueKeysWithValues: videos.map { ($0.id, VideoReceiver(stream: $0.id)) })
    }

    func submit(keyframe: Bool) {
        for sender in senders.values {
            sender.submit(EncodedFrame(isKeyframe: keyframe, payload: Bytes(repeating: 0xab, count: 40_000),
                                       codecConfig: keyframe ? CodecConfig(vps: [1], sps: [2], pps: [3]) : nil,
                                       captureTimeMicros: now),
                          now: now, datagramSize: 1200, budget: host.latencyBudget)
        }
    }

    func run(for duration: UInt64) throws {
        let end = now + duration
        while now < end {
            now += 250
            let due = inFlight.filter { $0.at <= now }
            inFlight.removeAll { $0.at <= now }
            for packet in due {
                let connection = packet.toHost ? host : client
                let header = try #require(ProtectedHeader(packet.bytes))
                let inbound = try #require(connection.receive(packet.bytes, header: header,
                    from: packet.toHost ? clientAddress : hostAddress, now: now))
                for item in inbound {
                    switch item {
                    case .fragment(let fragment):
                        receivers[fragment.stream]?.receive(fragment, now: now, budget: client.latencyBudget)
                    case .nack(let nack): senders[nack.stream]?.handle(nack, now: now, srtt: host.rtt.smoothed)
                    case .refresh: refreshRequests += 1
                    case .message(let stream, let bytes):
                        if packet.toHost { messagesAtHost[stream, default: []].append(bytes) }
                        else { messagesAtClient[stream, default: []].append(bytes) }
                    default: break
                    }
                }
            }
            for stream in receivers.keys.sorted() {
                let receiver = receivers[stream]!
                for chunk in receiver.poll(now: now, srtt: client.rtt.smoothed, budget: client.latencyBudget,
                                           lastHeard: client.lastReceived) { client.queue(chunk) }
                for frame in receiver.takeFrames() {
                    frames[stream, default: []].append(frame.frameID)
                    receiver.decoded(frameID: frame.frameID, isKeyframe: frame.header.frameType == .idr)
                }
            }
            for packet in host.flush(now: now) { try send(packet, toHost: false) }
            for stream in senders.keys.sorted() {
                for packet in senders[stream]!.drain(now: now, datagramSize: 1200, seal: { host.seal($0, now: self.now) }) {
                    try send(packet, toHost: false)
                }
            }
            for packet in client.flush(now: now) { try send(packet, toHost: true) }
        }
    }

    private func send(_ packet: Bytes, toHost: Bool) throws {
        let header = try #require(ProtectedHeader(packet))
        // These bounded runs never wrap the transport sequence.
        let body = try #require(Packet.open(packet, packetNumber: UInt64(header.transportSeq),
                                           key: TrafficKey(toHost ? clientKey : hostKey)))
        if dropFilter?(Chunk.parse(body).chunks, toHost) == true { return }
        inFlight.append((now + 2_000 + UInt64.random(in: 0...500, using: &rng), packet, toHost))
    }
}

@Test(arguments: NetworkScenario.all)
private func lostNacksAreRetriedWithoutRefreshingOtherStreams(scenario: NetworkScenario) throws {
    let link = InspectableTransport(scenario: scenario)
    link.submit(keyframe: true)
    try link.run(for: 100_000)
    for stream in link.senders.keys { try #require(link.frames[stream] == [1]) }
    let firstMissing = 4 + UInt16(scenario.seed % 4)
    var fragmentsDropped = 0
    var nacksDropped = 0
    var nacksDelivered = 0
    var nackDropEnd: UInt64?
    link.dropFilter = { [unowned link] chunks, toHost in
        if !toHost, chunks.contains(where: { chunk in
            guard case .mediaFragment(let fragment) = chunk else { return false }
            return fragment.stream == 1 && fragment.frameID == 2 && !fragment.isParity
                && fragment.flags & MediaFragment.Flag.retransmission == 0
                && (firstMissing..<firstMissing + 12).contains(fragment.index)
        }) {
            fragmentsDropped += 1
            return true
        }
        if toHost, chunks.contains(where: { if case .nack(let nack) = $0 { nack.stream == 1 } else { false } }) {
            if nackDropEnd == nil { nackDropEnd = link.now + 15_000 }
            if link.now < nackDropEnd! { nacksDropped += 1; return true }
            nacksDelivered += 1
        }
        return false
    }
    link.submit(keyframe: false)
    try link.run(for: 200_000)
    #expect(fragmentsDropped == 12 && nacksDropped > 0 && nacksDelivered > 0)
    #expect(link.senders[1]!.stats.retransmissions > 0)
    #expect(link.refreshRequests == 0)
    for stream in link.senders.keys {
        #expect(link.frames[stream] == [1, 2])
        #expect(link.receivers[stream]!.stats.framesLost == 0)
        #expect(link.senders[stream]!.stats.keyframes == 1)
        if stream != 1 {
            #expect(link.receivers[stream]!.stats.nackedFragments == 0)
            #expect(link.senders[stream]!.stats.retransmissions == 0)
        }
    }
}

@Test(arguments: NetworkScenario.all)
private func lostInputAcksReleaseRetainedMessagesWithoutDuplicates(scenario: NetworkScenario) throws {
    let link = InspectableTransport(scenario: scenario)
    let dropUntil = link.now + 200_000
    var acksDropped = 0
    var firstMessageTransmissions = 0
    link.dropFilter = { [unowned link] chunks, toHost in
        if toHost {
            firstMessageTransmissions += chunks.filter {
                if case .reliable(let segment) = $0 { segment.stream == 4 && segment.msgSeq == 0 } else { false }
            }.count
        }
        if !toHost, link.now < dropUntil, chunks.contains(where: {
            if case .feedback(let feedback) = $0 { !feedback.acks.isEmpty } else { false }
        }) {
            acksDropped += 1
            return true
        }
        return false
    }
    var sent: [UInt8: [Bytes]] = [:]
    for _ in 0..<8 {
        for message in [InputMessage.key(usage: 4, down: true, isRepeat: false), .key(usage: 4, down: false, isRepeat: false),
                        .button(.left, down: true), .button(.left, down: false)] {
            let stream: UInt8 = message.device == .keyboard ? 4 : 5
            #expect(link.client.send(message: message.encoded, on: stream))
            sent[stream, default: []].append(message.encoded)
        }
    }
    // The opposite direction's segmented reliable command and its ACK remain available.
    let control = Bytes(repeating: 0x5a, count: 2_500)
    #expect(link.host.send(message: control, on: 0))
    try link.run(for: 100_000)
    #expect(acksDropped > 0 && link.client.memoryBudget.usedBytes > 0)
    #expect(link.messagesAtHost == sent)
    #expect(link.messagesAtClient[0] == [control] && link.host.memoryBudget.usedBytes == 0)
    try link.run(for: 600_000)
    #expect((2...10).contains(firstMessageTransmissions))
    #expect(link.messagesAtHost == sent && link.messagesAtClient[0] == [control])
    #expect(link.client.memoryBudget.usedBytes == 0)
    #expect(link.host.memoryBudget.usedBytes == 0)
}

/// Losing the return path pauses the host and preserves reliable sequence numbers; losing the
/// forward path past the client's timeout replaces the session. Both recover without duplicates.
@Test(arguments: NetworkScenario.all, [FailedDirection.uplink, .downlink])
private func oneWayOutageResetsInputAndRecovers(scenario: NetworkScenario, direction: FailedDirection) throws {
    let link = scenario.makeLink()
    link.client.start(now: link.now)
    link.run(for: 500_000, frameEvery: 16_667)
    let original = try #require(link.client.session?.connection.sessionID)
    var sent: [InputMessage] = [.key(usage: 4, down: true, isRepeat: false), .button(.left, down: true)]
    for message in sent { #expect(link.client.send(message, now: link.now)) }
    link.run(for: 100_000, frameEvery: 16_667)
    expectInputs(link, sent)
    link.hostEvents.removeAll()
    link.clientEvents.removeAll()
    link.dropFilter = { _, toHost in toHost == (direction == .uplink) }
    let pending: [InputMessage] = [.key(usage: 4, down: false, isRepeat: false), .button(.left, down: false)]
        + (0..<8).map { .scroll(dx: 0, dy: Int16($0), units: .pixels) }
    for message in pending {
        #expect(link.client.send(message, now: link.now))
        sent.append(message)
    }
    link.run(for: 200_000, frameEvery: 16_667)
    if direction == .downlink { expectInputs(link, sent) }
    else { #expect(link.inputs.count == 2) }
    link.run(for: direction == .uplink ? 2_100_000 : 5_100_000, frameEvery: 16_667)
    if direction == .uplink {
        #expect(link.hostEvents.filter { $0 == .paused }.count == 1)
        #expect(!link.host.isStreaming)
        #expect(link.client.session?.connection.sessionID == original)
        #expect((1...300).contains(link.filteredToHost))
    } else {
        #expect(link.clientEvents.contains { if case .disconnected = $0 { true } else { false } })
        #expect(link.hostEvents.contains { if case .sessionEnded = $0 { true } else { false } })
        #expect(link.filteredToClient > 100)
    }
    // These reset events are the contract HostApp uses to release injected keys and buttons.
    let restoredAt = link.now
    let counts = link.deliveredOn.mapValues(\.count)
    link.dropFilter = nil
    link.run(for: 2_000_000, frameEvery: 16_667)
    try #require(link.client.isConnected && link.host.isStreaming)
    if direction == .uplink {
        #expect(link.client.session?.connection.sessionID == original)
        #expect(link.hostEvents.contains(.resumed))
    } else {
        #expect(link.client.session?.connection.sessionID != original)
    }
    // Frame identifiers restart with a fresh handshake, so inspect each epoch separately below.
    if direction == .uplink { try expectFreshVideo(link, since: restoredAt, countsBefore: counts) }
    else {
        for stream in link.streams {
            let resumed = Array(link.deliveredOn[stream, default: []].dropFirst(counts[stream, default: 0]))
            #expect(resumed.count >= 30 && resumed.first?.header.frameType == .idr)
            #expect(Set(resumed.map(\.frameID)).count == resumed.count)
            #expect(zip(resumed, resumed.dropFirst()).allSatisfy {
                $1.frameID > $0.frameID && ($1.frameID == $0.frameID + 1 || $1.header.frameType == .idr)
            })
            #expect(link.now - UInt64(try #require(resumed.last).header.captureTimeMicros) < 150_000)
        }
    }
    for message in [InputMessage.key(usage: 6, down: true, isRepeat: false), .key(usage: 6, down: false, isRepeat: false),
                    .button(.right, down: true), .button(.right, down: false)] {
        #expect(link.client.send(message, now: link.now))
        sent.append(message)
    }
    link.run(for: 200_000, frameEvery: 16_667)
    expectInputs(link, sent)
}
