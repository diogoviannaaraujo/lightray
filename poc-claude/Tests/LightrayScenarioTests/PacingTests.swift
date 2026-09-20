import LightrayCore
import LightrayEngine
import LightrayTestSupport
import Testing

/// Pacing and the v0 bitrate policy: manual, with a loss backstop.
@Suite("Pacing and bitrate")
struct PacingTests {

    /// A 30 Mbps bottleneck with the bitrate set to 50 Mbps: queuing delay rises,
    /// the backstop engages at the floor, and the client is told about it.
    @Test func bottleneckEngagesTheLossBackstop() {
        var link = SimulatedNetwork.LinkModel.clean(delay: .milliseconds(2))
        link.bitsPerSecond = 12_000_000
        link.queueCapacityBytes = 32 * 1500
        var config = SessionConfig()
        config.bitrate = 30_000_000
        config.bitrateFloor = 2_000_000
        var engine = EngineConfig()
        engine.lossWindow = .milliseconds(500)
        engine.lossBackstopWindows = 4
        engine.lossBackstopThreshold = 0.10

        let h = Harness(hostToClient: link, clientToHost: .clean(delay: .milliseconds(2)),
                        config: config, engine: engine)
        h.connect()
        h.advance(.milliseconds(50))
        h.startStreaming()
        h.advance(.seconds(5))

        let queuing = h.client.connection?.path.queuingDelay ?? .zero
        #expect(queuing > .milliseconds(5), "queuing delay rose to \(queuing.millis) ms")
        #expect(!h.backstopEvents.isEmpty, "the backstop engaged")
        #expect(h.backstopEvents.first == config.bitrateFloor, "clamped to the floor")
        #expect(h.hostConnection?.backstopEngaged == true)
        // The client learns about it through STATE{backstop}, so its UI can say so.
        #expect(h.client.connection?.peerBackstopEngaged == true,
                "the client received STATE{backstop}")
    }

    /// There is no automatic ramp-up: only a manual RECONFIGURE raises the
    /// bitrate again once the backstop has clamped it.
    @Test func onlyAManualReconfigureLeavesTheBackstop() {
        var link = SimulatedNetwork.LinkModel.clean(delay: .milliseconds(2))
        link.bitsPerSecond = 12_000_000
        var config = SessionConfig()
        config.bitrate = 30_000_000
        let h = Harness(hostToClient: link, config: config)
        h.connect()
        h.advance(.milliseconds(50))
        h.startStreaming()
        h.advance(.seconds(4))
        #expect(h.hostConnection?.backstopEngaged == true)

        h.stopStreaming()
        h.advance(.seconds(2))
        #expect(h.hostConnection?.backstopEngaged == true, "a quiet link does not un-clamp it")

        var request = ControlBody(message: .reconfigure)
        request.bitrate = 20_000_000
        h.hostConnection?.reconfigure(request)
        h.advance(.milliseconds(200))
        #expect(h.hostConnection?.backstopEngaged == false)
        #expect(h.hostConnection?.targetBitrate == 20_000_000)
    }

    /// A 500 KB IDR through the pacer: the bottleneck queue peak stays bounded
    /// against an unpaced baseline that dumps the whole frame at once.
    @Test func thePacerBoundsTheBottleneckQueue() {
        func peakQueue(paced: Bool) -> Int {
            var link = SimulatedNetwork.LinkModel.clean(delay: .milliseconds(2))
            link.bitsPerSecond = 200_000_000
            link.queueCapacityBytes = 4 << 20        // deep enough to measure, not drop
            var engine = EngineConfig()
            if !paced {
                // The unpaced baseline: no ceiling and a burst budget big enough
                // to hold the whole frame.
                engine.linkRateCeiling = 100_000_000_000
                engine.maxBurstBytes = 2 << 20
                engine.pacingGain = 10_000
            }
            let h = Harness(hostToClient: link, engine: engine)
            h.connect()
            h.advance(.milliseconds(50))
            var source = SyntheticFrameSource(stream: 1, bitrate: 20_000_000, framerate: 60)
            let idr = source.next(at: h.now, forceIDR: true)
            #expect(idr.storage.bytes.count > 400_000, "a 500 KB IDR")
            h.submitToHost(idr)
            h.advance(.milliseconds(300))
            return h.network.peakQueueBytes[.hostToClient] ?? 0
        }

        let pacedPeak = peakQueue(paced: true)
        let unpacedPeak = peakQueue(paced: false)
        #expect(pacedPeak > 0 && unpacedPeak > 0)
        #expect(pacedPeak < unpacedPeak / 2,
                "paced peak \(pacedPeak) B against unpaced \(unpacedPeak) B")
    }
}
