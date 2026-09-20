import LightrayCore
import LightrayEngine
import LightrayTestSupport
import Testing

/// The control channel: RECONFIGURE is the one path for every parameter, and the
/// reverse-direction streams use the same machinery as the forward ones.
@Suite("Control and bidirectional")
struct ControlTests {

    /// A RECONFIGURE round trip: the result reports what was actually applied and
    /// `config_generation` bumps.
    @Test func reconfigureRoundTrip() {
        let h = Harness()
        h.connect()
        h.advance(.milliseconds(50))
        let generationBefore = h.client.connection!.config.generation

        var request = ControlBody(message: .reconfigure)
        request.bitrate = 8_000_000
        request.framerate = 30
        request.resolution = (1280, 720)
        let reqID = h.client.reconfigure(request)!
        h.advance(.milliseconds(200))

        // The host applied it.
        let hostConfig = h.hostConnection!.config
        #expect(hostConfig.bitrate == 8_000_000)
        #expect(hostConfig.framerate == 30)
        #expect(hostConfig.width == 1280 && hostConfig.height == 720)
        #expect(hostConfig.generation > generationBefore, "the generation bumped")

        // And the client got a result that matches.
        let result = h.reconfigureResults.first { $0.0 == reqID }
        #expect(result != nil, "a RECONFIGURE_RESULT came back for request \(reqID)")
        #expect(result?.2 == 0, "nothing was rejected")
        #expect(result?.1.bitrate == 8_000_000)
        #expect(result?.1.framerate == 30)
        #expect(result?.1.generation == hostConfig.generation)
    }

    /// A value out of range is reported as rejected rather than silently clamped.
    @Test func anOutOfRangeReconfigureIsRejected() {
        let h = Harness()
        h.connect()
        h.advance(.milliseconds(50))

        var request = ControlBody(message: .reconfigure)
        request.framerate = 1000                  // above the accepted range
        let reqID = h.client.reconfigure(request)!
        h.advance(.milliseconds(200))

        let result = h.reconfigureResults.first { $0.0 == reqID }
        #expect(result != nil)
        #expect(result?.2 != 0, "the rejected mask names the field")
        #expect(h.hostConnection?.config.framerate == 60, "and the old value stands")
    }

    /// Bidirectional traffic at 5% loss: host video and audio one way, client mic
    /// and camera the other, plus reliable input. The input arrives complete and
    /// in order, which is the whole point of a reliable stream.
    @Test func bidirectionalTrafficWithReliableInput() {
        let streams = [
            StreamDescriptor(id: 1, kind: .video, direction: .hostToClient, streamClass: .media),
            StreamDescriptor(id: 2, kind: .audio, direction: .hostToClient, streamClass: .realtime),
            StreamDescriptor(id: 3, kind: .mic, direction: .clientToHost, streamClass: .realtime),
            StreamDescriptor(id: 4, kind: .camera, direction: .clientToHost, streamClass: .media),
            StreamDescriptor(id: 5, kind: .input, direction: .clientToHost, streamClass: .reliable),
        ]
        var lossy = SimulatedNetwork.LinkModel.clean(delay: .milliseconds(3))
        lossy.lossRate = 0.05
        var config = SessionConfig()
        config.bitrate = 8_000_000

        let h = Harness(hostToClient: lossy, clientToHost: lossy, config: config, streams: streams)
        h.connect()
        h.advance(.milliseconds(50))
        h.videoSource = SyntheticFrameSource(stream: 1, bitrate: 8_000_000, framerate: 60)
        h.audioSource = SyntheticFrameSource(stream: 2, bitrate: 128_000, framerate: 50)
        h.clientSources = [
            SyntheticFrameSource(stream: 3, bitrate: 96_000, framerate: 50, seed: 11),
            SyntheticFrameSource(stream: 4, bitrate: 2_000_000, framerate: 30, seed: 12),
        ]
        h.startStreaming()

        // 40 input messages, each tagged with its index.
        for i in 0..<40 {
            h.sendInput([UInt8(truncatingIfNeeded: i), 0xAA, UInt8(truncatingIfNeeded: i >> 8)], stream: 5)
            h.advance(.milliseconds(25))
        }
        h.advance(.seconds(2))

        let input = h.hostReliableMessages.filter { $0.0 == 5 }
        #expect(input.count == 40, "all 40 input messages arrived (got \(input.count))")
        #expect(input.map { Int($0.1[0]) } == Array(0..<40), "and in order")

        // Media flowed both ways.
        #expect(h.delivered.contains { $0.stream == 1 }, "host video reached the client")
        #expect(h.delivered.contains { $0.stream == 2 }, "host audio reached the client")
        #expect(h.delivered.contains { $0.stream == 3 }, "the client's mic reached the host")
        #expect(h.delivered.contains { $0.stream == 4 }, "the client's camera reached the host")
    }
}
