import CryptoKit
import LightrayCore
import LightrayCrypto
@testable import LightrayEngine
import LightrayTestSupport
import Testing

@Suite("Engine")
struct EngineTests {

    /// The rebind rule in full: a packet from a new address moves the session
    /// only if it authenticates, passes the replay window, and is newer than
    /// anything seen. This checks the third condition, which is the one an
    /// off-path attacker would try to exploit by replaying an old packet.
    @Test func anOldPacketFromANewAddressDoesNotRebind() {
        let h = Harness()
        h.connect()
        h.startStreaming()
        h.advance(.milliseconds(300))
        let host = h.hostConnection!
        let originalPeer = host.peer
        #expect(h.reboundCount == 0)

        // Take a datagram the client really sent, then let the link deliver it,
        // so the host has already recorded its packet number.
        guard let captured = h.network.lastOffered[.clientToHost], captured.count >= 32 else {
            Issue.record("the client sent nothing to replay")
            return
        }
        h.advance(.milliseconds(50))
        let dropsBefore = host.path.replayDropped + host.path.datagramsDropped

        // Now the same bytes from an attacker's address.
        let attacker = PeerAddress.synthetic(99, port: 6666)
        captured.withUnsafeBytes { raw in
            host.handle(datagram: raw, from: attacker, at: h.now)
        }
        #expect(host.peer == originalPeer, "the session did not move")
        #expect(host.path.replayDropped + host.path.datagramsDropped > dropsBefore,
                "the replay was counted, not acted on")
        #expect(host.path.rebinds == 0)
    }

    /// A last fragment that arrives before any other must still be placed, which
    /// is why `stride` is on the wire rather than inferred.
    @Test func theLastFragmentCanArriveFirst() {
        let pool = BufferPool()
        let reassembler = Reassembler(stream: 1, pool: pool, maxFramesInFlight: 4)
        let stride = 100
        let count = 4
        let now = Instant(nanos: 1_000_000)
        let deadline = Interval.milliseconds(50)

        // Fragment 3 is the last and short: 250 bytes total for the frame.
        var completion: Reassembler.Acceptance = .rejected
        let tail = [UInt8](repeating: 3, count: 50)
        tail.withUnsafeBytes { raw in
            let span = RawSpan(_unsafeBytes: raw)
            completion = reassembler.accept(
                FragmentHeader(stream: 1, flags: [], frameID: 5, index: 3, count: UInt16(count),
                               stride: UInt16(stride)),
                payload: span, at: now, deadline: deadline)
        }
        guard case .progress = completion else {
            Issue.record("the last fragment should be accepted first: \(completion)")
            return
        }

        // Then the rest, out of order.
        for index in [1, 0, 2] {
            let body = [UInt8](repeating: UInt8(index), count: stride)
            body.withUnsafeBytes { raw in
                let span = RawSpan(_unsafeBytes: raw)
                completion = reassembler.accept(
                    FragmentHeader(stream: 1, flags: [], frameID: 5, index: UInt16(index),
                                   count: UInt16(count), stride: UInt16(stride)),
                    payload: span, at: now, deadline: deadline)
            }
        }
        guard case .complete(let slot) = completion else {
            Issue.record("the frame should be complete: \(completion)")
            return
        }
        guard let done = reassembler.takeCompleted(slot) else {
            Issue.record("the completed frame should be available")
            return
        }
        defer { reassembler.recycle(done.buffer) }
        #expect(done.byteCount == 3 * stride + 50, "exact length, from the last fragment")
        // Each fragment landed at index x stride.
        let bytes = UnsafeRawBufferPointer(rebasing: done.buffer[..<done.byteCount])
        #expect(bytes[0] == 0)
        #expect(bytes[stride] == 1)
        #expect(bytes[2 * stride] == 2)
        #expect(bytes[3 * stride] == 3)
    }

    @Test func aDuplicateFragmentIsCountedNotPlacedTwice() {
        let pool = BufferPool()
        let reassembler = Reassembler(stream: 1, pool: pool, maxFramesInFlight: 4)
        let body = [UInt8](repeating: 7, count: 100)
        let header = FragmentHeader(stream: 1, flags: [], frameID: 1, index: 0, count: 3, stride: 100)
        var first: Reassembler.Acceptance = .rejected
        var second: Reassembler.Acceptance = .rejected
        body.withUnsafeBytes { raw in
            let span = RawSpan(_unsafeBytes: raw)
            first = reassembler.accept(header, payload: span, at: .zero, deadline: .milliseconds(50))
            second = reassembler.accept(header, payload: span, at: .zero, deadline: .milliseconds(50))
        }
        guard case .progress = first else { Issue.record("first should progress"); return }
        guard case .duplicate = second else { Issue.record("second should be a duplicate"); return }
        #expect(reassembler.stats.fragmentsDuplicate == 1)
        reassembler.flush()
    }

    /// The decodability gate, kind by kind. A gap stops `.previous` frames but
    /// must not stop the recovery frame that fixes it.
    @Test func decodabilityGateAcceptsRecoveryFrames() {
        var tracker = DecodabilityTracker(forceIDROnly: false, maxAckedLTR: 16)
        func header(_ type: FrameType, _ ref: RefKind, refID: UInt32? = nil) -> FrameHeader {
            FrameHeader(frameType: type, refKind: ref, configGeneration: 0,
                        captureTimeMicros: 0, refFrameID: refID)
        }

        // Nothing has been delivered: only an IDR gets through.
        #expect(tracker.verdict(for: header(.predicted, .previous), frameID: 1) == .undecodable)
        #expect(tracker.verdict(for: header(.idr, .none), frameID: 1) == .deliver)
        tracker.recordDelivered(frameID: 1, isKeyframe: true)

        // In sync: the next predicted frame is fine.
        #expect(tracker.verdict(for: header(.predicted, .previous), frameID: 2) == .deliver)
        tracker.recordDelivered(frameID: 2, isKeyframe: false)
        // Out of sequence: frame 4 needs frame 3.
        #expect(tracker.verdict(for: header(.predicted, .previous), frameID: 4) == .undecodable)

        // A gap closes the gate for predicted frames.
        tracker.recordGap()
        #expect(tracker.verdict(for: header(.predicted, .previous), frameID: 3) == .undecodable)
        // With nothing acked, ltrAny cannot be trusted either.
        #expect(tracker.verdict(for: header(.predicted, .ltrAny), frameID: 5) == .undecodable)
        // Once the receiver has acked a frame as decoded, ltrAny is sound: the
        // encoder can only have chosen from that set.
        tracker.recordDecodedLTR(frameID: 2)
        #expect(tracker.verdict(for: header(.predicted, .ltrAny), frameID: 5) == .deliver)
        // An explicit LTR reference must name a frame in the acked set.
        #expect(tracker.verdict(for: header(.predicted, .ltr, refID: 2), frameID: 5) == .deliver)
        #expect(tracker.verdict(for: header(.predicted, .ltr, refID: 99), frameID: 5) == .undecodable)
        // An IDR always works.
        #expect(tracker.verdict(for: header(.idr, .none), frameID: 6) == .deliver)
    }

    @Test func forcingIDROnlyRejectsEveryLTRReference() {
        var tracker = DecodabilityTracker(forceIDROnly: true, maxAckedLTR: 16)
        tracker.recordDelivered(frameID: 1, isKeyframe: true)
        tracker.recordDecodedLTR(frameID: 1)
        let ltrAny = FrameHeader(frameType: .predicted, refKind: .ltrAny, configGeneration: 0,
                                 captureTimeMicros: 0)
        #expect(tracker.verdict(for: ltrAny, frameID: 2) == .undecodable)
        // Ordinary predicted frames still flow: IDR-only is about recovery.
        let previous = FrameHeader(frameType: .predicted, refKind: .previous, configGeneration: 0,
                                   captureTimeMicros: 0)
        #expect(tracker.verdict(for: previous, frameID: 2) == .deliver)
    }

    @Test func theAckedLTRSetIsBounded() {
        var set = LTRAckSet(limit: 4)
        for id in 1...10 { set.record(UInt32(id)) }
        #expect(set.candidates.count == 4, "the set is capped, which bounds FRAME_ACK traffic too")
        #expect(set.candidates == [7, 8, 9, 10], "and keeps the newest")
        set.record(10)
        #expect(set.candidates.count == 4, "a duplicate ack changes nothing")
    }

    @Test func pacerSpendsTokensAndRefillsOverTime() {
        var pacer = Pacer(rate: 1_000_000, maxBurstBytes: 12_000, at: .zero)   // 1 MB/s
        let burstAvailable = pacer.take(12_000)
        let spent = pacer.take(1)
        #expect(burstAvailable, "the initial burst is available")
        #expect(!spent, "and then it is spent")

        // 1 ms at 1 MB/s is 1000 bytes.
        pacer.refill(at: Instant(nanos: 1_000_000))
        let refilled = pacer.take(1_000)
        let spentAgain = pacer.take(1)
        #expect(refilled)
        #expect(!spentAgain)

        // The engine arms a timer for when the next datagram becomes affordable
        // rather than spinning.
        let next = pacer.nextAvailable(bytes: 1_200, from: Instant(nanos: 1_000_000))
        #expect(next != nil)
        #expect(next! > Instant(nanos: 1_000_000))

        // Control traffic is never delayed, so it may overdraw.
        pacer.takeUnconditionally(5_000)
        let overdrawn = pacer.take(1)
        #expect(!overdrawn)
    }

    @Test func pacerRateFollowsTheLargerOfBitrateAndBacklog() {
        var config = EngineConfig()
        config.pacingGain = 1.25
        config.spreadTarget = 0.8
        config.linkRateCeiling = 400_000_000

        let interval = Interval(nanos: 16_666_667)
        // A quiet link: the bitrate term wins. 20 Mbps x 1.25 / 8 = 3.125 MB/s.
        let idle = Pacer.rate(targetBitrate: 20_000_000, frameBytes: 0, frameInterval: interval,
                              config: config)
        #expect(abs(idle - 3_125_000) < 1_000)

        // A 500 KB IDR queued: it has to leave inside 80% of a frame interval,
        // so the rate jumps to spread it.
        let burst = Pacer.rate(targetBitrate: 20_000_000, frameBytes: 500_000,
                               frameInterval: interval, config: config)
        #expect(burst > idle * 10, "the backlog raises the rate to \(Int(burst)) B/s")
        // But never past the ceiling, which is what bounds the momentary burst.
        #expect(burst <= Double(config.linkRateCeiling) / 8)
        let huge = Pacer.rate(targetBitrate: 20_000_000, frameBytes: 50_000_000,
                              frameInterval: interval, config: config)
        #expect(huge == Double(config.linkRateCeiling) / 8)
    }

    @Test func theBackstopNeedsSeveralBadWindowsAndOnlyManualRecovery() {
        var config = EngineConfig()
        config.lossWindow = .milliseconds(500)
        config.lossBackstopWindows = 4
        config.lossBackstopThreshold = 0.10
        var controller = BitrateController(target: 50_000_000, floor: 2_000_000,
                                           config: config, at: .zero)
        var now = Instant.zero

        // Three bad windows are not enough: a transient does not clamp the link.
        for window in 1...3 {
            for _ in 0..<80 { controller.recordDelivered() }
            for _ in 0..<20 { controller.recordLost() }       // 20% loss
            now = now + .milliseconds(500)
            let outcome = controller.tick(at: now)
            #expect(outcome == .unchanged, "window \(window)")
        }
        for _ in 0..<80 { controller.recordDelivered() }
        for _ in 0..<20 { controller.recordLost() }
        now = now + .milliseconds(500)
        let clamped = controller.tick(at: now)
        #expect(clamped == .clamped(2_000_000), "the fourth bad window clamps")
        #expect(controller.backstopEngaged)
        #expect(controller.target == 2_000_000)

        // A clean window does not ramp back up: there is no automatic recovery.
        for _ in 0..<100 { controller.recordDelivered() }
        now = now + .milliseconds(500)
        let afterCleanWindow = controller.tick(at: now)
        #expect(afterCleanWindow == .unchanged)
        #expect(controller.backstopEngaged)
        #expect(controller.target == 2_000_000)

        // Only a manual RECONFIGURE raises it.
        controller.setManualTarget(20_000_000)
        #expect(!controller.backstopEngaged)
        #expect(controller.target == 20_000_000)
    }

    @Test func reliableChannelSegmentsAndReordersIntoPlace() {
        var channel = ReliableChannel(stream: 0)
        let message = (0..<250).map { UInt8(truncatingIfNeeded: $0) }
        channel.send(message, maxSegmentBytes: 100)
        var segments: [ReliableChannel.Segment] = []
        var now = Instant.zero
        while let segment = channel.nextSendable(at: now, rto: .seconds(1)) {
            segments.append(segment)
            channel.markSent(msgSeq: segment.msgSeq, index: segment.index, at: now)
            now = now + .microseconds(10)
        }
        #expect(segments.count == 3, "250 bytes in 100-byte segments")
        #expect(segments.map(\.count) == [3, 3, 3])

        // Deliver them out of order: nothing comes out until the message is whole.
        var receiver = ReliableChannel(stream: 0)
        var delivered: [[UInt8]] = []
        for index in [2, 0, 1] {
            let segment = segments[index]
            segment.bytes.withUnsafeBytes { raw in
                let span = RawSpan(_unsafeBytes: raw)
                delivered.append(contentsOf: receiver.receive(
                    ReliableHeader(stream: 0, msgSeq: segment.msgSeq, segIndex: segment.index,
                                   segCount: segment.count),
                    payload: span))
            }
        }
        #expect(delivered.count == 1)
        #expect(delivered.first == message, "reassembled in order from out-of-order segments")
    }

    @Test func aReliableSegmentIsResentAfterItsRTO() {
        var channel = ReliableChannel(stream: 0)
        channel.send([1, 2, 3], maxSegmentBytes: 100)
        let rto = Interval.milliseconds(50)
        guard let first = channel.nextSendable(at: .zero, rto: rto) else {
            Issue.record("nothing to send"); return
        }
        channel.markSent(msgSeq: first.msgSeq, index: first.index, at: .zero)
        let insideRTO = channel.nextSendable(at: Instant(nanos: 10_000_000), rto: rto)
        let pastRTO = channel.nextSendable(at: Instant(nanos: 60_000_000), rto: rto)
        #expect(insideRTO == nil, "in flight and inside its RTO")
        #expect(pastRTO != nil, "past its RTO it goes again")
        channel.markAcked(msgSeq: first.msgSeq, index: first.index)
        let afterAck = channel.nextSendable(at: Instant(nanos: 60_000_000), rto: rto)
        #expect(afterAck == nil, "and once acked it is done")
        #expect(!channel.hasPendingOutbound)
    }

    @Test func theRetransmitStoreEvictsByAgeAndBytes() {
        var store = RetransmitStore(duration: .milliseconds(500), byteLimit: 1 << 20)
        let pool = BufferPool()
        func frame(_ id: UInt32, bytes: Int, at: Instant) -> SendFrame {
            SendFrame(stream: 1, frameID: id, storage: HeapStorage(byteCount: bytes),
                      headerBuffer: pool.takeLarge(64), headerLength: 11, stride: 1149,
                      flags: [], submittedAt: at, deadline: at + .milliseconds(50),
                      ltrMarked: true, pool: pool)
        }
        store.insert(frame(1, bytes: 100_000, at: .zero))
        store.insert(frame(2, bytes: 100_000, at: Instant(nanos: 16_000_000)))
        #expect(store.frameCount == 2)
        #expect(store.frame(1, 1) != nil, "a NACK for frame 1 can still be answered")

        // Past the age limit, the oldest goes.
        store.trim(now: Instant(nanos: 600_000_000))
        #expect(store.frame(1, 1) == nil, "evicted, so the only honest answer is a refresh")

        // Duplicate suppression inside srtt/2.
        var fresh = RetransmitStore(duration: .milliseconds(500), byteLimit: 1 << 20)
        fresh.insert(frame(3, bytes: 1_000, at: .zero))
        let srtt = Interval.milliseconds(20)
        let firstAttempt = fresh.shouldRetransmit(frameID: 3, index: 0, now: .zero, srtt: srtt)
        let tooSoon = fresh.shouldRetransmit(frameID: 3, index: 0, now: Instant(nanos: 5_000_000), srtt: srtt)
        let later = fresh.shouldRetransmit(frameID: 3, index: 0, now: Instant(nanos: 20_000_000), srtt: srtt)
        #expect(firstAttempt)
        #expect(!tooSoon, "a second NACK inside srtt/2 does not resend")
        #expect(later, "but a later one does")
    }
}
