import LightrayCore
import LightrayEngine
import LightrayTestSupport
import Testing

@Suite("Smoke")
struct SmokeTests {
    @Test func handshakeEstablishesASession() {
        let h = Harness()
        h.connect()
        h.advance(.milliseconds(50))
        #expect(h.client.phase == .connected)
        #expect(h.host.sessionCount == 1)
        #expect(h.clientEvents.contains("established"))
        #expect(h.client.connection?.capabilities.contains(.ltr) == true)
    }

    @Test func framesFlowHostToClient() {
        let h = Harness()
        h.connect()
        h.advance(.milliseconds(50))
        h.streaming = true
        h.advance(.milliseconds(500))
        let frames = h.videoFrames
        #expect(frames.count >= 20, "delivered \(frames.count) frames in 500 ms at 60 fps")
        #expect(frames.first?.isKeyframe == true)
        #expect(frames.first?.hadCodecConfig == true)
        // Frame ids are contiguous and payload content survives reassembly.
        for (i, f) in frames.enumerated() where i > 0 {
            #expect(f.frameID == frames[i - 1].frameID + 1)
        }
        #expect(h.undecodable.isEmpty)
    }
}
