import CoreVideo
import Foundation
import LightrayCore
import Testing
@testable import lightray_host

/// Delivers exactly one frame during start, then stays completely still. Moving synthetic
/// sources hide both losing that first callback and waiting for another frame on reconnect.
private final class StillSource: FrameSource {
    let width = 320
    let height = 240
    let queue: DispatchQueue
    let pixels: CVPixelBuffer
    var onFrame: ((CVPixelBuffer, UInt64) -> Void)?
    var onFailure: ((String) -> Void)?
    var isCapturing = false

    init(queue: DispatchQueue) throws {
        self.queue = queue
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        pixels = try #require(buffer)
    }

    func start() async throws {
        queue.sync {
            isCapturing = true
            onFrame?(pixels, monotonicMicros())
        }
    }

    func stop() { isCapturing = false }
}

private final class RecordingEncoder: FrameEncoder {
    struct Frame { let pixels: CVPixelBuffer; let keyframe: Bool }
    var frames: [Frame] = [] // Read on the pipeline queue.
    var invalidated = false
    func encode(_ pixels: CVPixelBuffer, captureTimeMicros: UInt64, forceKeyframe: Bool) {
        #expect(!invalidated)
        frames.append(Frame(pixels: pixels, keyframe: forceKeyframe))
    }
    func invalidate() { invalidated = true }
}

private final class Fixture {
    let queue = DispatchQueue(label: "pipeline.test")
    let source: StillSource
    let encoder = RecordingEncoder()
    let pipeline: Pipeline

    init() throws {
        source = try StillSource(queue: queue)
        pipeline = Pipeline(stream: 1, display: HostDisplays.testPatterns(width: 320, height: 240)[0],
                            queue: queue, source: source, encoder: encoder)
    }
    deinit { pipeline.stop() }
    var frames: [RecordingEncoder.Frame] { queue.sync { encoder.frames } }
}

@Test func firstConnectionUsesThePictureDeliveredDuringCaptureStartup() async throws {
    let f = try Fixture()
    try await f.pipeline.start()
    #expect(f.frames.isEmpty) // Prepared capture does not encode while no client is connected.
    f.pipeline.setStreaming(true)
    let first = try #require(f.frames.first)
    #expect(first.keyframe)
    #expect(first.pixels === f.source.pixels)
    #expect(f.frames.count == 1)
}

@Test func keyframeRequestedBeforeResumeIsSentWithoutAnotherCapture() async throws {
    let f = try Fixture()
    try await f.pipeline.start()
    f.pipeline.setStreaming(true)
    #expect(f.frames.count == 1)
    f.pipeline.setStreaming(false)
    f.pipeline.requestKeyframe() // Handshake event arrives before async display setup completes.
    #expect(f.frames.count == 1)
    f.pipeline.setStreaming(true)
    #expect(f.frames.count == 2)
    #expect(f.frames.last?.keyframe == true)
    f.pipeline.setStreaming(true) // Repeated binding must not produce a burst of refreshes.
    #expect(f.frames.count == 2)
}

@Test func aConnectedStillDesktopRemainsLiveWithoutFullRateEncoding() async throws {
    let f = try Fixture()
    try await f.pipeline.start()
    f.pipeline.setStreaming(true)
    try await Task.sleep(for: .milliseconds(1400))
    #expect(f.frames.count == 2)
    #expect(f.frames.last?.keyframe == false)
    f.pipeline.setStreaming(false)
    let pausedCount = f.frames.count
    try await Task.sleep(for: .milliseconds(1400))
    #expect(f.frames.count == pausedCount)
}

@Test func stoppedCaptureDoesNotReplayAnOldDesktop() async throws {
    let f = try Fixture()
    try await f.pipeline.start()
    f.pipeline.setStreaming(true)
    #expect(f.frames.count == 1)
    f.pipeline.stop()
    f.pipeline.setStreaming(true)
    f.pipeline.requestKeyframe()
    f.queue.sync { f.source.onFrame?(f.source.pixels, monotonicMicros()) }
    #expect(f.frames.count == 1)
    #expect(!f.pipeline.isCapturing)
    #expect(f.queue.sync { f.encoder.invalidated })
}

@Test func idleCaptureKeepsTheNewestPictureReadyWithoutEncodingIt() async throws {
    let f = try Fixture()
    try await f.pipeline.start()
    f.pipeline.setStreaming(true)
    #expect(f.frames.count == 1)
    f.pipeline.setStreaming(false)
    let changed = try StillSource(queue: f.queue)
    f.queue.sync { f.source.onFrame?(changed.pixels, monotonicMicros()) }
    #expect(f.frames.count == 1)
    f.pipeline.setStreaming(true)
    let resumed = try #require(f.frames.last)
    #expect(f.frames.count == 2)
    #expect(resumed.keyframe && resumed.pixels === changed.pixels)
}

@Test func failedSourceCannotBeKeptArtificiallyLiveByCachedRefreshes() async throws {
    let f = try Fixture()
    try await f.pipeline.start()
    f.pipeline.setStreaming(true)
    #expect(f.frames.count == 1)
    f.queue.sync { f.source.stop() }
    f.pipeline.requestKeyframe()
    f.pipeline.setStreaming(false)
    f.pipeline.setStreaming(true)
    try await Task.sleep(for: .milliseconds(1400))
    #expect(f.frames.count == 1)
    #expect(!f.pipeline.isCapturing)
}
