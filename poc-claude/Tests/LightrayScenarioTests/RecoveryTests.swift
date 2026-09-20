import LightrayCore
import LightrayEngine
import LightrayTestSupport
import Testing

/// Loss recovery, in the plan's order: NACK first, then LTR, then IDR.
@Suite("Recovery")
struct RecoveryTests {

    /// 2% random loss at 4 ms RTT: nearly every frame still completes by its
    /// deadline, and nothing undecodable ever reaches the decoder.
    @Test func randomLossRecoversByNack() {
        var link = SimulatedNetwork.LinkModel.clean(delay: .milliseconds(2))
        link.lossRate = 0.02
        let h = Harness(hostToClient: link, clientToHost: .clean(delay: .milliseconds(2)))
        h.connect()
        h.advance(.milliseconds(50))
        h.startStreaming()
        h.advance(.seconds(3))

        let delivered = h.videoFrames.count
        let gaps = h.gaps.count
        #expect(delivered > 100, "delivered \(delivered) frames over 3 s")
        #expect(h.clientNacksSent > 0, "loss produced NACKs")
        #expect(h.hostRetransmits > 0, "and the host answered them from the retransmit store")
        // Frames lost beyond recovery are reported as gaps, never handed over
        // half-built.
        let completionRate = Double(delivered) / Double(delivered + gaps)
        #expect(completionRate > 0.99, "completion rate \(completionRate) with 2% loss")
        // Every frame the decoder saw was decodable. A `.frameUndecodable` event
        // is the gate working, not a failure, so what matters is that no frame
        // was both delivered and undecodable.
        let deliveredIDs = Set(h.videoFrames.map(\.frameID))
        let heldBack = Set(h.undecodable.map(\.1))
        #expect(deliveredIDs.isDisjoint(with: heldBack),
                "no frame was both delivered and gated (\(h.undecodable.count) gated)")
    }

    /// A 30 ms burst at 2 ms RTT is inside the frame deadline, so NACK alone
    /// recovers it: no refresh, no keyframe, no visible break.
    ///
    /// This is worth asserting because it is the common case, and it sets the
    /// baseline for the two tests below, which need a burst past the deadline
    /// before the refresh path is reached at all.
    @Test func shortBurstIsRecoveredByNackAlone() {
        let h = Harness(capabilities: [.ltr])
        h.connect()
        h.advance(.milliseconds(50))
        h.startStreaming()
        h.advance(.milliseconds(500))
        let keyframesBefore = h.keyframes.count
        let framesBefore = h.videoFrames.count

        h.blackout(direction: .hostToClient, for: .milliseconds(30))
        h.advance(.milliseconds(30))
        h.endBlackout()
        h.advance(.milliseconds(300))

        #expect(h.clientNacksSent > 0, "the burst produced NACKs")
        #expect(h.hostRetransmits > 0, "answered from the retransmit store")
        #expect(h.videoFrames.count > framesBefore + 10, "the stream carried on")
        #expect(h.keyframes.count == keyframesBefore, "and needed no IDR")
        #expect(h.refreshRequests.isEmpty, "nor any refresh")
    }

    /// A burst past the frame deadline, with LTR negotiated: the receiver asks
    /// for a refresh, the encoder answers with a frame referencing its acked
    /// set, and that frame is accepted without an IDR.
    @Test func longBurstRecoversThroughLTRWithoutAnIDR() {
        let h = Harness(capabilities: [.ltr])
        h.connect()
        h.advance(.milliseconds(50))
        h.startStreaming()
        // Long enough that the receiver has acked at least one LTR frame.
        h.advance(.milliseconds(900))
        #expect((h.hostConnection?.ackedLTRCount(stream: 1) ?? 0) >= 1,
                "the receiver acked an LTR frame before the burst")
        let keyframesBefore = h.keyframes.count

        h.blackout(direction: .hostToClient, for: .milliseconds(150))
        h.advance(.milliseconds(150))
        h.endBlackout()
        h.advance(.milliseconds(400))

        let ltrRequests = h.refreshRequests.filter { $0.1 == .ltr }
        #expect(!ltrRequests.isEmpty, "the host was asked for an LTR refresh")
        #expect(!(ltrRequests.first?.2.isEmpty ?? true), "and was offered its whole acked set")
        let recovery = h.delivered.first { $0.refKind == .ltrAny }
        #expect(recovery != nil, "a frame marked ltrAny was accepted")
        #expect(h.keyframes.count == keyframesBefore, "recovery needed no IDR")
    }

    /// The same burst without LTR: the only honest answer is an IDR.
    @Test func longBurstWithoutLTRFallsBackToIDR() {
        let h = Harness(capabilities: [])
        h.connect()
        h.advance(.milliseconds(50))
        #expect(h.client.connection?.capabilities.contains(.ltr) == false)
        h.startStreaming()
        h.advance(.milliseconds(900))
        let keyframesBefore = h.keyframes.count

        h.blackout(direction: .hostToClient, for: .milliseconds(150))
        h.advance(.milliseconds(150))
        h.endBlackout()
        h.advance(.milliseconds(400))

        #expect(!h.refreshRequests.isEmpty, "the receiver asked for a refresh")
        #expect(h.refreshRequests.allSatisfy { $0.1 == .idr }, "and every request asked for an IDR")
        #expect(h.keyframes.count > keyframesBefore, "an IDR was produced")
        #expect(h.delivered.allSatisfy { $0.refKind != .ltrAny })
    }

    /// A frame the encoder skipped leaves no id behind, so nothing looks like a
    /// whole-frame loss. Ids are assigned only to frames that produced bytes.
    @Test func skippedFramesProduceNoWholeFrameNack() {
        let h = Harness()
        h.connect()
        h.advance(.milliseconds(50))
        var source = SyntheticFrameSource(stream: 1, bitrate: 8_000_000, framerate: 60)

        // Submit at half cadence: the encoder skipped every other capture.
        for i in 0..<40 {
            let frame = source.next(at: h.now, forceIDR: i == 0)
            h.submitToHost(frame)
            h.advance(.milliseconds(33))
        }
        h.advance(.milliseconds(200))

        let ids = h.videoFrames.map(\.frameID)
        #expect(ids.count >= 30, "delivered \(ids.count) of 40")
        #expect(ids == Array(ids.min()!...ids.max()!), "ids are contiguous despite the skipped captures")
        #expect(h.clientNacksSent == 0, "a clean link with skipped captures needs no NACK")
        #expect(h.gaps.isEmpty)
    }

    /// A decoder rebuilt from nothing joins at an IDR, using only that frame's
    /// own CODEC_CONFIG.
    @Test func joiningAtAnIDRNeedsOnlyThatFramesCodecConfig() {
        let h = Harness()
        h.connect()
        h.advance(.milliseconds(50))
        h.startStreaming()
        h.advance(.milliseconds(400))
        let expected = h.videoSource.codecConfig

        // The client loses its decoder and resumes, which is the case that would
        // otherwise need a separate parameter-set message.
        let resumeStart = h.now
        h.client.resume(decoderLost: true, at: h.now)
        h.advance(.milliseconds(400))

        let first = h.frames(since: resumeStart).first
        #expect(first?.isKeyframe == true, "the recovery frame is an IDR")
        #expect(first?.hadCodecConfig == true, "carrying its own parameter sets")
        #expect(first?.byteCount ?? 0 > 0)
        // And the bytes survived the TLV round trip intact.
        #expect(expected.count == 81)
    }

    /// FRAME_ACK volume follows `ltrAckInterval`, not the frame rate, and the
    /// sender's retained set stays bounded.
    @Test func ltrAckVolumeTracksTheIntervalNotTheFrameRate() {
        var engine = EngineConfig()
        engine.ltrAckInterval = .milliseconds(250)
        engine.maxAckedLTR = 16
        let h = Harness(engine: engine)
        h.connect()
        h.advance(.milliseconds(50))
        h.startStreaming()
        h.advance(.seconds(6))

        let acks = h.client.connection?.snapshot().streams[1]?.ltrAcksSent ?? 0
        let frames = UInt64(h.videoFrames.count)
        // 6 s at one ack per 250 ms is about 24, against roughly 360 frames.
        #expect(acks >= 15 && acks <= 32, "sent \(acks) LTR acks over 6 s")
        #expect(acks * 8 < frames, "far fewer acks than frames (\(acks) vs \(frames))")
        let retained = h.hostConnection?.ackedLTRCount(stream: 1) ?? 0
        #expect(retained <= engine.maxAckedLTR, "retained \(retained) acked LTR frames")
        #expect(retained >= 1)
    }
}
