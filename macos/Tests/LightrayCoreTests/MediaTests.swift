import Testing

@testable import LightrayCore

/// Fragments of one frame as a sender would build them.
func fragments(frameID: UInt32, frame: Bytes, stride: Int = 100, stream: UInt8 = 1) -> [MediaFragment] {
    let count = (frame.count + stride - 1) / stride
    return (0..<count).map { i in
        MediaFragment(
            stream: stream, flags: 0, frameID: frameID, index: UInt16(i), count: UInt16(count), stride: UInt16(stride),
            payload: frame[i * stride..<min((i + 1) * stride, frame.count)])
    }
}

func frame(idr: Bool, size: Int, seed: UInt8 = 0) -> Bytes {
    let header = FrameHeader(
        frameType: idr ? .idr : .predicted, refKind: idr ? .none : .previous, captureTimeMicros: 0,
        codecConfig: idr ? CodecConfig(vps: [1], sps: [2], pps: [3]) : nil)
    return header.encoded + (0..<size).map { UInt8(truncatingIfNeeded: $0) &+ seed }
}

/// Conformance test 5: the last fragment first, then the rest out of order.
@Test func reassemblesInAnyOrder() throws {
    let receiver = VideoReceiver(stream: 1)
    let bytes = frame(idr: true, size: 950)
    var parts = fragments(frameID: 1, frame: bytes)
    parts = [parts.last!] + parts.dropLast().reversed()
    for (i, part) in parts.enumerated() {
        receiver.receive(part, now: UInt64(i), budget: 50_000)
    }
    let delivered = receiver.takeFrames()
    #expect(delivered.count == 1)
    #expect(delivered.first?.bytes == bytes)
    #expect(delivered.first?.header.codecConfig?.sps == [2])
}

/// Conformance test 6: a retransmission answered after delivery is not delivered again.
@Test func lateRetransmissionIsNotDeliveredTwice() {
    let receiver = VideoReceiver(stream: 1)
    let parts = fragments(frameID: 1, frame: frame(idr: true, size: 300))
    for part in parts { receiver.receive(part, now: 0, budget: 50_000) }
    #expect(receiver.takeFrames().count == 1)
    receiver.receive(parts[1], now: 10, budget: 50_000)
    #expect(receiver.takeFrames().isEmpty)
    #expect(receiver.stats.redundantFragments == 1)
}

/// A predicted frame that completes before the keyframe ahead of it is held, not discarded.
@Test func deliversInOrderAndGatesPredictedFrames() {
    let receiver = VideoReceiver(stream: 1)
    let idr = fragments(frameID: 1, frame: frame(idr: true, size: 500))
    let p = fragments(frameID: 2, frame: frame(idr: false, size: 50))
    receiver.receive(idr[0], now: 0, budget: 50_000)
    for part in p { receiver.receive(part, now: 1, budget: 50_000) }
    #expect(receiver.takeFrames().isEmpty)
    for part in idr.dropFirst() { receiver.receive(part, now: 2, budget: 50_000) }
    #expect(receiver.takeFrames().map(\.frameID) == [1, 2])

    // A predicted frame with no keyframe before it is never delivered, and a keyframe is asked for.
    let fresh = VideoReceiver(stream: 1)
    for part in fragments(frameID: 1, frame: frame(idr: false, size: 50)) { fresh.receive(part, now: 0, budget: 50_000) }
    #expect(fresh.takeFrames().isEmpty)
    let chunks = fresh.poll(now: 1, srtt: 10_000, budget: 50_000)
    #expect(chunks.contains { if case .refreshRequest(let r) = $0 { r.preferred == .idr } else { false } })
}

@Test func nacksOnlyHolesBelowTheHighestIndex() {
    let receiver = VideoReceiver(stream: 1)
    let parts = fragments(frameID: 1, frame: frame(idr: true, size: 950))  // 10 fragments
    receiver.receive(parts[0], now: 0, budget: 100_000)
    receiver.receive(parts[3], now: 0, budget: 100_000)
    // Within the reorder window: nothing.
    #expect(receiver.poll(now: 500, srtt: 4_000, budget: 100_000).isEmpty)
    // After it: fragments 1 and 2, not the unsent-looking tail.
    #expect(receiver.poll(now: 1_500, srtt: 4_000, budget: 100_000) == [
        .nack(Nack(stream: 1, entries: [NackEntry(frameID: 1, first: 1, count: 2)]))
    ])
    // Not again until the retry interval.
    #expect(receiver.poll(now: 3_000, srtt: 4_000, budget: 100_000).isEmpty)
    // The tail, after two frame intervals.
    let late = receiver.poll(now: 40_000, srtt: 4_000, budget: 100_000)
    #expect(late == [.nack(Nack(stream: 1, entries: [
        NackEntry(frameID: 1, first: 1, count: 2), NackEntry(frameID: 1, first: 4, count: 6),
    ]))])
}

@Test func asksForAWholeFrameThatNeverArrived() {
    let receiver = VideoReceiver(stream: 1)
    for part in fragments(frameID: 1, frame: frame(idr: true, size: 50)) { receiver.receive(part, now: 0, budget: 50_000) }
    for part in fragments(frameID: 3, frame: frame(idr: false, size: 50)) { receiver.receive(part, now: 0, budget: 50_000) }
    #expect(receiver.takeFrames().map(\.frameID) == [1])
    #expect(receiver.poll(now: 2_000, srtt: 4_000, budget: 50_000) == [
        .nack(Nack(stream: 1, entries: [NackEntry(frameID: 2, first: 0, count: 0)]))
    ])
    // Past the deadline frame 2 is given up; frame 3 cannot be decoded without it.
    let chunks = receiver.poll(now: 60_000, srtt: 4_000, budget: 50_000)
    #expect(receiver.takeFrames().isEmpty)
    #expect(receiver.stats.framesLost == 1 && receiver.stats.framesUndecodable == 1)
    guard case .refreshRequest(let request) = chunks.last else {
        Issue.record("no refresh request")
        return
    }
    #expect(request.reason == .loss && request.lostFrame == 3 && request.lastGoodFrame == 1)
    // Repeated with the same identifier, at most once a round trip.
    #expect(receiver.poll(now: 61_000, srtt: 4_000, budget: 50_000).isEmpty)
    guard case .refreshRequest(let again) = receiver.poll(now: 71_000, srtt: 4_000, budget: 50_000).last else {
        Issue.record("no repeat")
        return
    }
    #expect(again.reqID == request.reqID)
    // A keyframe that decodes ends the attempt.
    for part in fragments(frameID: 4, frame: frame(idr: true, size: 50)) { receiver.receive(part, now: 72_000, budget: 50_000) }
    #expect(receiver.takeFrames().map(\.frameID) == [4])
    receiver.decoded(frameID: 4, isKeyframe: true)
    #expect(receiver.poll(now: 200_000, srtt: 4_000, budget: 50_000).isEmpty)
}

/// Regression scenario: frame identifiers advance through 0xffffffff to 1, and the `PREVIOUS`
/// chain holds across the wrap.
@Test func frameIdentifiersWrapPastZero() {
    let sender = VideoSender(stream: 1, bitrate: 10_000_000, frameRate: 60, firstFrameID: .max - 1)
    let receiver = VideoReceiver(stream: 1, firstFrameID: .max - 1)
    var now: UInt64 = 0
    for i in 0..<4 {
        sender.submit(
            EncodedFrame(isKeyframe: i == 0, payload: Bytes(repeating: 9, count: 2000), codecConfig: CodecConfig(vps: [1], sps: [2], pps: [3]), captureTimeMicros: now),
            now: now, datagramSize: 1200, budget: 50_000)
        for datagram in sender.drain(now: now, datagramSize: 1200, seal: { $0 }) {
            if case .mediaFragment(let f) = Chunk.parse(datagram).chunks.first! { receiver.receive(f, now: now, budget: 50_000) }
        }
        now += 16_667
    }
    #expect(receiver.takeFrames().map(\.frameID) == [.max - 1, .max, 1, 2])
}

/// The sender answers each refresh identifier once, and a NACK only within the frame's deadline.
@Test func senderAnswersRequestsOnce() {
    let sender = VideoSender(stream: 1, bitrate: 10_000_000, frameRate: 60)
    let request = RefreshRequest(stream: 1, reason: .loss, preferred: .idr, lastGoodFrame: 0, lostFrame: 1, reqID: 5)
    #expect(sender.handle(request, now: 0))
    #expect(!sender.handle(request, now: 1_000))
    var next = request
    next.reqID = 6
    #expect(sender.handle(next, now: 2_000))

    sender.submit(EncodedFrame(isKeyframe: false, payload: Bytes(repeating: 1, count: 3000), codecConfig: nil, captureTimeMicros: 0), now: 0, datagramSize: 1200, budget: 50_000)
    #expect(sender.drain(now: 0, datagramSize: 1200, seal: { $0 }).count == 3)
    sender.handle(Nack(stream: 1, entries: [NackEntry(frameID: 1, first: 1, count: 1)]), now: 10_000, srtt: 4_000)
    let resent = sender.drain(now: 10_000, datagramSize: 1200, seal: { $0 })
    #expect(resent.count == 1)
    if case .mediaFragment(let f) = Chunk.parse(resent[0]).chunks.first! {
        #expect(f.index == 1 && f.flags & MediaFragment.Flag.retransmission != 0)
    }
    sender.handle(Nack(stream: 1, entries: [NackEntry(frameID: 1, first: 0, count: 0)]), now: 60_000, srtt: 4_000)
    #expect(sender.drain(now: 60_000, datagramSize: 1200, seal: { $0 }).isEmpty)
}

@Test func pacingBoundsBursts() {
    let sender = VideoSender(stream: 1, bitrate: 20_000_000, frameRate: 60)
    sender.submit(EncodedFrame(isKeyframe: false, payload: Bytes(repeating: 0, count: 200_000), codecConfig: nil, captureTimeMicros: 0), now: 0, datagramSize: 1200, budget: 100_000)
    let first = sender.drain(now: 0, datagramSize: 1200, seal: { $0 })
    #expect(first.count == 32)
    // The backlog drains within about a frame interval.
    var sent = first.count
    var now: UInt64 = 0
    while sender.hasBacklog, now < 100_000 {
        now = sender.nextDeadline(now: now)!
        sent += sender.drain(now: now, datagramSize: 1200, seal: { $0 }).count
    }
    #expect(sent == 175)
    #expect(now < 20_000)
}

@Test(arguments: [256, 512, 1200, 9000])
func generatedNacksRespectDatagramLimit(size: Int) throws {
    let receiver = VideoReceiver(stream: 1)
    for index in stride(from: 0, through: 318, by: 2) {
        receiver.receive(MediaFragment(stream: 1, flags: 0, frameID: 1, index: UInt16(index), count: 320, stride: 200, payload: Bytes(repeating: 0, count: 200)[...]), now: 1_000, budget: 50_000)
    }
    let key = Bytes(repeating: 7, count: 32)
    let connection = Connection(role: .client, sessionID: 1, sendKey: key, receiveKey: key, streams: StreamTable([]), maxDatagramSize: size, peer: PeerAddress(ip: [192, 0, 2, 1], port: 7373), now: 1_000)
    var requested: [NackEntry] = []
    var packetNumber: UInt64 = 0
    for now in [UInt64(10_000), 10_001] {
        for chunk in receiver.poll(now: now, srtt: 2_000, budget: 50_000) { connection.queue(chunk) }
        for datagram in connection.flush(now: now) {
            #expect(datagram.count <= size)
            let body = try #require(Packet.open(datagram, packetNumber: packetNumber, key: TrafficKey(key)))
            packetNumber += 1
            for chunk in Chunk.parse(body).chunks {
                if case .nack(let nack) = chunk { requested += nack.entries }
            }
        }
    }
    #expect(requested.map(\.first).sorted() == stride(from: 1, through: 317, by: 2).map { UInt16($0) })
    #expect(requested.allSatisfy { $0.frameID == 1 && $0.count == 1 })
}

@Test func oversizedDatagramsAreNotSealed() {
    let key = Bytes(repeating: 7, count: 32)
    let connection = Connection(role: .client, sessionID: 1, sendKey: key, receiveKey: key, streams: StreamTable([]), maxDatagramSize: 256, peer: PeerAddress(ip: [192, 0, 2, 1], port: 7373), now: 0)
    #expect(connection.seal(Bytes(repeating: 0, count: 256), now: 1) == nil)
    #expect(!connection.queue(.datagram(stream: 1, payload: Bytes(repeating: 0, count: 256))))
    #expect(connection.flush(now: 2).allSatisfy { $0.count <= 256 })
    #expect(connection.stats.oversizedOutgoing == 2)
}

@Test(arguments: [UInt16(0), 65, .max])
func receiverRejectsInvalidParityLength(length: UInt16) {
    let receiver = VideoReceiver(stream: 1)
    let fragment = MediaFragment(stream: 1, flags: MediaFragment.Flag.parity, frameID: 1, index: 0, count: 1, stride: 64, fec: .init(maxBlockLength: 1, parityPerBlock: 1, lastLength: length), payload: Bytes(repeating: 0, count: 64)[...])
    receiver.receive(fragment, now: 1_000, budget: 50_000)
    #expect(receiver.stats.discardedFragments == 1)
    #expect(receiver.takeFrames().isEmpty)
}

@Test func reliableStreamsDeliverInOrderOnce() {
    let sender = ReliableSender(stream: 4)
    let receiver = ReliableReceiver(stream: 4)
    for i in 0..<5 { #expect(sender.enqueue([UInt8(i)] + Bytes(repeating: 0, count: i * 10), maxSegmentPayload: 16)) }
    let segments = sender.due(now: 0, timeout: 20_000)
    #expect(segments.count == 1 + 1 + 2 + 2 + 3)
    var delivered: [Bytes] = []
    var acks = 0
    for segment in segments.reversed() {
        if case .accepted(let ack, let deliver) = receiver.receive(segment) {
            if ack { acks += 1 }
            delivered += deliver
        }
    }
    #expect(delivered.map(\.first) == [0, 1, 2, 3, 4])
    #expect(acks == 5)
    // A duplicate is acknowledged again and not delivered.
    #expect(receiver.receive(segments[0]) == .accepted(ack: true, deliver: []))
    // Unacknowledged messages come back after the timeout, doubling.
    #expect(sender.due(now: 10_000, timeout: 20_000).isEmpty)
    #expect(sender.due(now: 20_000, timeout: 20_000).count == 9)
    #expect(sender.due(now: 50_000, timeout: 20_000).isEmpty)
    for seq in 0..<5 { sender.acknowledge(UInt32(seq)) }
    #expect(sender.isIdle)
}

@Test func inputMessagesRoundTrip() {
    let messages: [InputMessage] = [
        .key(usage: 0x04, down: true, isRepeat: false), .key(usage: 0xe3, down: false, isRepeat: true),
        .pointer(x: 0, y: 65535, display: 0x0102_0304), .button(.right, down: true), .scroll(dx: -3, dy: 240, units: .wheelNotch120),
        .scroll(dx: 0, dy: -12, units: .pixels),
    ]
    for message in messages { #expect(InputMessage(message.encoded) == message) }
    #expect(InputMessage.key(usage: 0x04, down: true, isRepeat: false).encoded == [0x01, 0x00, 0x04, 0x01])
    // A pointer message without the display, as the first version sent it, means display 0.
    #expect(InputMessage([0x10, 0x00, 0x01, 0x00, 0x02]) == .pointer(x: 1, y: 2, display: 0))
    #expect(InputMessage([0x7f]) == nil)
    #expect(InputMessage([0x10, 0x00]) == nil)
}

@Test func controlMessagesRoundTrip() {
    let messages: [ControlMessage] = [
        .selectDisplay(reqID: 3, stream: 16, display: 9), .displaySelected(reqID: 3, stream: 16, display: 0),
        .streamDisplay(stream: 1, display: 7),
        .displays([
            DisplayInfo(id: 7, isPrimary: true, width: 1920, height: 1080, refreshMillihertz: 59_940, layoutX: -1920,
                        layoutY: 0, layoutWidth: 1920, layoutHeight: 1080, name: "Built-in Retina Display"),
        ]),
        .displays([]),
    ]
    for message in messages { #expect(ControlMessage(message.encoded) == message) }
    // The version 0 shape: msg_type, req_id, scope_stream, then TLVs.
    #expect(ControlMessage.selectDisplay(reqID: 3, stream: 16, display: 9).encoded == hex("010000000310f000040000000" + "9"))
    // A name longer than 64 bytes is cut at a character boundary.
    let long = DisplayInfo(id: 1, isPrimary: false, width: 1, height: 1, refreshMillihertz: 0, layoutX: 0, layoutY: 0,
                           layoutWidth: 1, layoutHeight: 1, name: String(repeating: "é", count: 40))
    guard case .displays(let parsed) = ControlMessage(ControlMessage.displays([long]).encoded) else {
        Issue.record("did not parse")
        return
    }
    #expect(parsed.first?.name == String(repeating: "é", count: 32))
    // Unknown messages, and TLVs that overrun, are refused.
    #expect(ControlMessage([0x77, 0, 0, 0, 0, 0]) == nil)
    #expect(ControlMessage([0x01, 0, 0, 0, 1, 1, 0xf0, 0x00, 0x08, 0, 0, 0, 1]) == nil)
}

/// Everything a sender with FEC sends for one frame, parsed back into fragments.
private func sent(_ frame: EncodedFrame, percent: Int = 10, minParity: Int = 1, id: inout UInt64) -> [MediaFragment] {
    let sender = VideoSender(stream: 1, bitrate: 1_000_000_000, frameRate: 60)
    sender.fecPercent = percent
    sender.fecMinParity = minParity
    sender.submit(frame, now: 0, datagramSize: 1200, budget: 100_000)
    var out: [MediaFragment] = []
    var now: UInt64 = 0
    while sender.hasBacklog {
        for datagram in sender.drain(now: now, datagramSize: 1200, seal: { $0 }) {
            if case .mediaFragment(let f) = Chunk.parse(datagram).chunks.first! { out.append(f) }
        }
        now += 1_000
    }
    id += 1
    return out
}

private func encoded(idr: Bool, size: Int, seed: UInt8 = 1) -> EncodedFrame {
    EncodedFrame(
        isKeyframe: idr, payload: (0..<size).map { UInt8(truncatingIfNeeded: $0 * 7) &+ seed },
        codecConfig: idr ? CodecConfig(vps: [1], sps: [2], pps: [3]) : nil, captureTimeMicros: 0)
}

/// A lost data fragment, the last one included, is rebuilt from parity with no NACK, and the
/// frame comes out byte for byte, cut back to its true length.
@Test func parityRebuildsWithoutAskingAgain() throws {
    var n: UInt64 = 0
    let frame = encoded(idr: true, size: 30_000)
    let parts = sent(frame, id: &n)
    let data = parts.filter { !$0.isParity }
    #expect(data.count == 27 && parts.count - data.count == 3)
    // Parity follows its block's data.
    #expect(parts.last!.isParity && !parts[26].isParity)
    for dropped in [5, 26] {
        let receiver = VideoReceiver(stream: 1)
        for part in parts where part.isParity || part.index != dropped { receiver.receive(part, now: 0, budget: 100_000) }
        let delivered = receiver.takeFrames()
        let header = FrameHeader(frameType: .idr, refKind: .none, captureTimeMicros: 0, codecConfig: frame.codecConfig)
        #expect(delivered.first?.bytes == header.encoded + frame.payload)
        #expect(receiver.stats.fecRepaired == 1)
        #expect(receiver.poll(now: 50_000, srtt: 4_000, budget: 100_000).isEmpty)
    }
}

/// Parity covers what it can; the NACK asks only for the rest, once the block is known sent.
@Test func nackAsksOnlyForWhatParityCannotCover() {
    var n: UInt64 = 0
    // 9 data fragments and 1 parity: losing 3 leaves a deficit of 2.
    let parts = sent(encoded(idr: true, size: 10_000), id: &n)
    #expect(parts.count == 10 && parts.last!.isParity)
    let receiver = VideoReceiver(stream: 1)
    for part in parts where part.isParity || ![2, 3, 6].contains(part.index) { receiver.receive(part, now: 0, budget: 100_000) }
    #expect(receiver.takeFrames().isEmpty)
    let nack = receiver.poll(now: 2_000, srtt: 4_000, budget: 100_000)
    #expect(nack == [.nack(Nack(stream: 1, entries: [NackEntry(frameID: 1, first: 2, count: 2)]))])
    // The two retransmissions and the parity complete it: fragment 6 is rebuilt.
    receiver.receive(parts[2], now: 5_000, budget: 100_000)
    #expect(receiver.takeFrames().isEmpty)
    receiver.receive(parts[3], now: 5_000, budget: 100_000)
    #expect(receiver.takeFrames().map(\.frameID) == [1])
    #expect(receiver.stats.fecRepaired == 1)
}

/// Late is not lost: a frame whose fragments are held up by a silent link past its deadline is
/// delivered when they arrive, with no keyframe asked for.
@Test func aSilentLinkDoesNotExpireFrames() {
    let receiver = VideoReceiver(stream: 1)
    for part in fragments(frameID: 1, frame: frame(idr: true, size: 300)) { receiver.receive(part, now: 0, budget: 50_000) }
    let second = fragments(frameID: 2, frame: frame(idr: false, size: 500))
    receiver.receive(second[0], now: 10_000, budget: 50_000)
    #expect(receiver.takeFrames().map(\.frameID) == [1])
    // Nothing heard since 10 ms: no deadline fires, and none is scheduled.
    for now in stride(from: UInt64(20_000), through: 250_000, by: 10_000) {
        let chunks = receiver.poll(now: now, srtt: 20_000, budget: 50_000, lastHeard: 10_000)
        #expect(!chunks.contains { if case .refreshRequest = $0 { true } else { false } })
    }
    #expect(receiver.nextDeadline(now: 250_000, srtt: 20_000, lastHeard: 10_000)! < 250_000 + 50_000)
    #expect(receiver.stats.framesLost == 0)
    // The link comes back after 240 ms; the rest of the frame is in the burst.
    receiver.linkResumed(after: 240_000)
    for part in second.dropFirst() { receiver.receive(part, now: 250_000, budget: 50_000) }
    _ = receiver.poll(now: 250_000, srtt: 20_000, budget: 50_000, lastHeard: 250_000)
    #expect(receiver.takeFrames().map(\.frameID) == [2])
    #expect(receiver.stats.framesLost == 0 && receiver.stats.refreshRequests == 0)

    // On a live link the same frame is given up at its deadline, as before.
    let live = VideoReceiver(stream: 1)
    for part in fragments(frameID: 1, frame: frame(idr: true, size: 300)) { live.receive(part, now: 0, budget: 50_000) }
    live.receive(second[0], now: 10_000, budget: 50_000)
    _ = live.poll(now: 70_000, srtt: 20_000, budget: 50_000, lastHeard: 65_000)
    #expect(live.stats.framesLost == 1)
}

/// The host answers a NACK held up by the client's stall: the stall pushes its deadline back.
@Test func senderGivesStalledClientsTheTimeBack() {
    let sender = VideoSender(stream: 1, bitrate: 10_000_000, frameRate: 60)
    sender.submit(EncodedFrame(isKeyframe: false, payload: Bytes(repeating: 1, count: 3000), codecConfig: nil, captureTimeMicros: 0), now: 0, datagramSize: 1200, budget: 50_000)
    #expect(sender.drain(now: 0, datagramSize: 1200, seal: { $0 }).count == 3)
    sender.extendDeadlines(by: 120_000)
    sender.handle(Nack(stream: 1, entries: [NackEntry(frameID: 1, first: 1, count: 1)]), now: 150_000, srtt: 4_000)
    #expect(sender.drain(now: 150_000, datagramSize: 1200, seal: { $0 }).count == 1)
    // The credit is bounded: a frame cannot be held open forever.
    sender.extendDeadlines(by: 10_000_000)
    sender.handle(Nack(stream: 1, entries: [NackEntry(frameID: 1, first: 0, count: 1)]), now: 460_000, srtt: 4_000)
    #expect(sender.drain(now: 460_000, datagramSize: 1200, seal: { $0 }).isEmpty)
}
