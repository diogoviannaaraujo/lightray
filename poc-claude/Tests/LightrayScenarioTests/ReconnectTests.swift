import LightrayCore
import LightrayEngine
import LightrayTestSupport
import Testing

/// Reconnect is the protocol's priority path: park, rebind, then resume on an IDR.
@Suite("Reconnect")
struct ReconnectTests {

    /// 20 s of client absence, inside `pipelineIdleAfter` so the pipeline is
    /// still warm: PARK, blackout, then a new source port.
    @Test func parkAndResumeWithinTheIdleWindow() {
        let h = Harness()
        h.connect()
        h.advance(.milliseconds(50))
        h.startStreaming()
        h.advance(.milliseconds(300))
        #expect(h.videoFrames.count > 10)

        let addressBeforePark = h.clientAddress
        h.client.park(at: h.now)
        h.advance(.milliseconds(100))
        #expect(h.parkedCount >= 1, "the host parks on PARK")
        #expect(h.hostConnection?.isParked == true)

        // While parked the host has released everything that could not reach an
        // absent peer.
        #expect(h.hostConnection?.retainedMediaBytes == 0)

        h.blackout(.seconds(20))
        h.advance(.seconds(20))
        #expect(h.pipelineIdleCount == 0, "20 s is inside the 60 s pipelineIdleAfter")
        h.endBlackout()

        let resumeStart = h.now
        h.client.resume(decoderLost: false, at: h.now)
        h.advance(.milliseconds(400))

        #expect(h.clientAddress != addressBeforePark, "a resume replaces the socket")
        #expect(h.resumedCount >= 1)
        let after = h.frames(since: resumeStart)
        #expect(!after.isEmpty, "frames flow again after the resume")
        // A resume is always an IDR.
        #expect(after.first?.isKeyframe == true)
        #expect(after.first?.hadCodecConfig == true)
        // Resume-to-first-frame latency is recorded.
        let latency = h.client.connection?.reconnect.resumeLatency
        #expect((latency?.count ?? 0) >= 1)
        #expect(h.hostConnection?.sessionID == h.client.connection?.sessionID,
                "the same session came back, not a new one")
    }

    /// Silent disappearance: the host parks on its own timeout, goes idle, and
    /// eventually expires the session.
    @Test func silentDisappearanceParksThenIdlesThenExpires() {
        var engine = EngineConfig()
        engine.parkAfterSilence = .seconds(2)
        engine.pipelineIdleAfter = .seconds(60)
        engine.graceWindow = .seconds(30 * 60)
        let h = Harness(engine: engine)
        h.connect()
        h.advance(.milliseconds(50))
        h.startStreaming()
        h.advance(.milliseconds(200))

        // The client vanishes without a PARK.
        h.blackout(.seconds(40 * 60))
        h.advance(.seconds(5))
        #expect(h.parkedCount >= 1, "the host parks after parkAfterSilence")

        let parkedFootprint = h.hostConnection?.retainedMediaBytes ?? -1
        #expect(parkedFootprint == 0, "parking releases every media buffer")

        h.advance(.seconds(70))
        #expect(h.pipelineIdleCount >= 1, "the app is told to tear the pipeline down")
        #expect(h.host.sessionCount == 1, "the session itself is untouched, so a late client still resumes")

        h.advance(.seconds(31 * 60))
        #expect(h.expiredCount >= 1, "the grace window ends the session")
        #expect(h.host.sessionCount == 0)
    }

    /// A client returning after the grace window gets SESSION_UNKNOWN, which is
    /// how it learns at once instead of retrying into the void.
    @Test func returningAfterTheGraceWindowGetsSessionUnknown() {
        var engine = EngineConfig()
        engine.parkAfterSilence = .milliseconds(500)
        engine.pipelineIdleAfter = .seconds(2)
        engine.graceWindow = .seconds(5)
        let h = Harness(engine: engine)
        h.connect()
        h.advance(.milliseconds(50))
        h.startStreaming()
        h.advance(.milliseconds(200))
        let originalSession = h.client.connection?.sessionID

        h.blackout(.seconds(8))
        h.advance(.seconds(8))
        #expect(h.expiredCount >= 1)
        h.endBlackout()

        h.client.resume(decoderLost: true, at: h.now)
        h.advance(.seconds(1))
        #expect(h.sessionLostCount >= 1, "the host answers with SESSION_UNKNOWN")
        #expect(h.client.phase == .lost)

        // The app re-handshakes, which succeeds against the same host.
        h.client.reHandshake(at: h.now)
        h.advance(.milliseconds(300))
        #expect(h.client.phase == .connected)
        #expect(h.client.connection?.sessionID != originalSession, "a fresh session, not the expired one")
    }

    /// A re-handshake that names a session the host still has parked is adopted
    /// with new keys: same session and stats, one round trip, no re-pairing.
    @Test func reHandshakeAdoptsAParkedSession() {
        var engine = EngineConfig()
        engine.parkAfterSilence = .milliseconds(300)
        let h = Harness(engine: engine)
        h.connect()
        h.advance(.milliseconds(50))
        h.startStreaming()
        h.advance(.milliseconds(200))
        let sessionID = h.client.connection!.sessionID

        h.client.park(at: h.now)
        h.advance(.seconds(1))
        #expect(h.hostConnection?.isParked == true)

        // The client re-handshakes rather than resuming, naming the parked session.
        let before = h.now
        h.client.connect(to: h.hostAddress, at: h.now, resuming: sessionID)
        h.advance(.milliseconds(400))
        #expect(h.client.phase == .connected)
        #expect(h.client.connection?.sessionID == sessionID, "the host adopted the parked session")
        #expect(h.client.reconnect.handshakesAdopted >= 1)
        let after = h.frames(since: before)
        #expect(after.first?.isKeyframe == true, "an adopted resume still forces an IDR")
    }

    /// NAT rebinding mid-stream: the address changes but the session was never
    /// parked, so the stream continues with no IDR.
    @Test func natRebindingContinuesWithoutAnIDR() {
        let h = Harness()
        h.connect()
        h.advance(.milliseconds(50))
        h.startStreaming()
        h.advance(.milliseconds(300))
        let keyframesBefore = h.keyframes.count
        let framesBefore = h.videoFrames.count

        // The address changes without any protocol event: a NAT rebinding.
        h.replaceClientSocket()
        h.advance(.milliseconds(300))

        #expect(h.reboundCount >= 1, "the host noticed the new address")
        #expect(h.videoFrames.count > framesBefore, "the stream carried on")
        #expect(h.keyframes.count == keyframesBefore, "and needed no IDR")
        #expect(h.parkedCount == 0)
        #expect(h.resumedCount == 0)
    }

}
