import CoreVideo
import Dispatch
import Foundation
import Testing
@testable import LightrayCore

@Test func decodeTimingsSeparateQueueWaitFromDecodeAndRejectInvalidClocks() throws {
    var timings = DecodeTimings()
    #expect(timings.meanDecodeMillis == nil && timings.meanQueueMillis == nil)
    timings.record(completedAt: 1_000, decodeStarted: 3_000, decodeFinished: 6_000)
    timings.record(completedAt: 10_000, decodeStarted: 14_000, decodeFinished: 19_000)
    #expect(timings.samples == 2 && timings.maximumDecodeMicros == 5_000)
    #expect(try #require(timings.meanDecodeMillis) == 4)
    #expect(try #require(timings.meanQueueMillis) == 3)
    timings.record(completedAt: 50, decodeStarted: 49, decodeFinished: 70)
    timings.record(completedAt: 0, decodeStarted: 80, decodeFinished: 79)
    #expect(timings.samples == 2)
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func next() -> UInt64 { lock.withLock { value += 1_000; return value } }
}

@Test func decoderReportsAndResetsOnlySuccessfulCurrentTimings() throws {
    let bytes = Bytes(hex: idrExample)!
    var (header, offset) = try #require(FrameHeader.parse(bytes))
    header.hostTimings = HostFrameTimings(captureMicros: 1200, encodeMicros: 3400, sampleID: 42)
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
    let pixels = try #require(pixelBuffer)
    let clock = TestClock()
    let done = DispatchSemaphore(value: 0)
    let worker = BoundedVideoDecoder(stream: 1, now: { clock.next() }) { frame in
        .picture(pixels, frameID: frame.frameID, isKeyframe: true)
    }
    worker.onResult = { _, _, _ in done.signal() }
    worker.submit(DeliveredFrame(frameID: 1, header: header, bytes: bytes, payloadOffset: offset, completedAt: 0))
    #expect(done.wait(timeout: .now() + 2) == .success)
    let timings = worker.takeTimings()
    #expect(timings.samples == 1 && timings.meanDecodeMillis == 1 && timings.meanQueueMillis == 3)
    #expect(timings.hostSamples == 1 && timings.lastHostSample == header.hostTimings)
    let empty = worker.takeTimings()
    #expect(empty.samples == 0 && empty.hostSamples == 0 && empty.lastHostSample == nil)
    worker.cancel()
}

@Test func decoderFailureDoesNotBecomeALatencySample() throws {
    let bytes = Bytes(hex: idrExample)!
    let (header, offset) = try #require(FrameHeader.parse(bytes))
    let done = DispatchSemaphore(value: 0)
    let worker = BoundedVideoDecoder(stream: 1, now: { 0 }) { .failed(frameID: $0.frameID, status: -1) }
    worker.onResult = { _, _, _ in done.signal() }
    worker.submit(DeliveredFrame(frameID: 1, header: header, bytes: bytes, payloadOffset: offset, completedAt: 0))
    #expect(done.wait(timeout: .now() + 2) == .success)
    #expect(worker.takeTimings().samples == 0)
    worker.cancel()
}

@Test func hostTimingsAverageOnlyAvailableSamplesAndReset() throws {
    var timings = DecodeTimings()
    let first = try #require(HostFrameTimings(captureMicros: 1000, encodeMicros: 2000, sampleID: 99))
    let last = try #require(HostFrameTimings(captureMicros: 3000, encodeMicros: 6000, sampleID: 101))
    timings.record(completedAt: 0, decodeStarted: 1, decodeFinished: 2, hostTimings: first)
    timings.record(completedAt: 0, decodeStarted: 1, decodeFinished: 2)
    timings.record(completedAt: 0, decodeStarted: 1, decodeFinished: 2, hostTimings: last)
    timings.record(completedAt: 9, decodeStarted: 1, decodeFinished: 2, hostTimings: first)
    #expect(timings.samples == 3 && timings.hostSamples == 2)
    #expect(timings.meanCaptureMillis == 2 && timings.meanEncodeMillis == 4)
    #expect(timings.lastHostSample == last)
    timings = DecodeTimings()
    #expect(timings.hostSamples == 0 && timings.lastHostSample == nil)
    #expect(timings.meanCaptureMillis == nil && timings.meanEncodeMillis == nil)
}
