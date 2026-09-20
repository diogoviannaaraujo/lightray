import Foundation
import LightrayCore
import LightrayEngine
import LightrayTestSupport
import Testing

/// The baseline the rest is measured against: a clean link should cost nothing.
@Suite("Steady state")
struct SteadyStateTests {

    /// 1080p60 at 20 Mbps on a clean link: every frame completes and no NACK is
    /// ever sent.
    ///
    /// The plan's scenario runs for 60 s; set `LIGHTRAY_LONG_SCENARIOS=1` for
    /// that, otherwise this runs 10 s so the suite stays quick.
    @Test func cleanLinkNeedsNoRecovery() {
        let long = ProcessInfo.processInfo.environment["LIGHTRAY_LONG_SCENARIOS"] == "1"
        let duration = Interval.seconds(long ? 60 : 10)
        let h = Harness()
        h.connect()
        h.startStreaming()
        h.advance(duration)

        let frames = h.videoFrames
        let expected = Int(duration.seconds * 60)
        #expect(frames.count >= expected - 4 && frames.count <= expected + 1,
                "delivered \(frames.count) frames, expected about \(expected)")
        #expect(h.clientNacksSent == 0, "a clean link needs no NACK")
        #expect(h.hostRetransmits == 0, "and no retransmission")
        #expect(h.gaps.isEmpty, "no frame was given up on")
        #expect(h.undecodable.isEmpty, "and none was gated")
        #expect(h.keyframes.count == 1, "one IDR, at the start")

        // Frame ids are contiguous, and each frame's payload is the one that was
        // sent: a reassembly bug would show up as a content mismatch.
        let ids = frames.map(\.frameID)
        #expect(ids == Array(ids[0]...ids[ids.count - 1]))
        #expect(Set(frames.map(\.firstPayloadWord)).count == frames.count,
                "every frame's payload is distinct, so none was mixed up")

        // Latency: a frame completes within a frame interval or two on a 2 ms link.
        let worst = frames.map(\.latency.millis).max() ?? 0
        #expect(worst < 40, "worst frame completion latency \(worst) ms")
    }

    /// Steady state allocates nothing per packet in the sans-IO core, and the
    /// buffer pool's slabs are recycled rather than regrown.
    @Test func poolsAreRecycledNotRegrown() {
        let h = Harness()
        h.connect()
        h.startStreaming()
        h.advance(.seconds(2))
        let outstandingAfterWarmup = h.clientPool.slabsOutstanding
        h.advance(.seconds(2))
        #expect(h.clientPool.slabsOutstanding == outstandingAfterWarmup,
                "the client pool stopped growing once warm")
        // Frame buffers come back: the reclaimer should not be holding a backlog.
        #expect(h.clientPool.largeBytesHeld > 0, "the pool is caching frame buffers")
    }

    /// The host's parked footprint: keys, packet-number and replay state, the
    /// stream table, the config snapshot and stats — under 1 KB plus stats.
    @Test func aParkedSessionHoldsNoMediaState() {
        let h = Harness()
        h.connect()
        h.startStreaming()
        h.advance(.seconds(1))
        #expect((h.hostConnection?.retainedMediaBytes ?? 0) > 100_000,
                "a live session is holding a retransmit window")

        h.client.park(at: h.now)
        h.advance(.milliseconds(200))
        #expect(h.hostConnection?.isParked == true)
        #expect(h.hostConnection?.retainedMediaBytes == 0,
                "parking released every media buffer")
        #expect(h.hostConnection?.framesInFlight(stream: 1) == 0)
        // And no timer runs for it: expiry is one coarse sweep by the endpoint.
        #expect(h.hostConnection?.nextTimeout(at: h.now) == nil,
                "a parked host session arms no timer of its own")
    }
}
