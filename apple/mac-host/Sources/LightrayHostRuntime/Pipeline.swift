import CoreVideo
import Foundation
import LightrayCore

protocol FrameEncoder: AnyObject {
    func encode(_ pixels: CVPixelBuffer, captureTimeMicros: UInt64, forceKeyframe: Bool)
    func invalidate()
}

extension VideoEncoder: FrameEncoder {}

/// Capture and encoding for one video stream showing one display. Each stream has its own, on a
/// queue of its own, so that nothing one display does reaches another (`docs/displays.md`).
final class Pipeline: @unchecked Sendable {
    let id: UUID
    let stream: UInt8
    let display: DisplayInfo
    private let queue: DispatchQueue
    private let source: FrameSource
    private let encoder: FrameEncoder
    private var refreshTimer: DispatchSourceTimer?
    var onFailure: ((String) -> Void)?

    // Owned by `queue`.
    private var lastPicture: CVPixelBuffer?
    private var keyframePending = true
    private var streaming = false
    private var stopped = false
    private var lastEncodedAt: UInt64 = 0

    init(id: UUID = UUID(), stream: UInt8, display: DisplayInfo, queue: DispatchQueue, source: FrameSource, encoder: FrameEncoder) {
        self.id = id
        self.stream = stream
        self.display = display
        self.queue = queue
        self.source = source
        self.encoder = encoder
        // Install before starting capture: a still desktop may deliver just one picture.
        source.onFrame = { [weak self] pixels, micros in self?.captured(pixels, at: micros) }
        source.onFailure = { [weak self] reason in self?.onFailure?(reason) }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            guard let self, !stopped, streaming, source.isCapturing, let lastPicture else { return }
            let now = monotonicMicros()
            // Keep a still desktop live on clients without encoding at the full frame rate.
            if now >= lastEncodedAt + 1_000_000 { encode(lastPicture, at: now) }
        }
        timer.schedule(deadline: .distantFuture)
        timer.resume()
        refreshTimer = timer
    }

    deinit { refreshTimer?.cancel() }

    /// Starts capturing `display` and creates an encoder of its size. Throws if either cannot
    /// start, which is how a host finds the limit of its hardware.
    static func start(
        id: UUID = UUID(), stream: UInt8, display: DisplayInfo, options: HostOptions,
        output: @escaping @Sendable (EncodedFrame) -> Void
    ) async throws -> Pipeline {
        let queue = DispatchQueue(label: "lightray.capture.\(stream)", qos: .userInteractive)
        let source: FrameSource
        if options.testPattern != nil {
            let pattern = TestPattern(
                width: display.width, height: display.height, frameRate: options.frameRate, variant: Int(display.id),
                queue: queue)
            source = pattern
        } else {
            source = ScreenCapture(display: display, frameRate: options.frameRate, scale: options.scale, queue: queue)
        }
        let encoder: VideoEncoder
        do {
            encoder = try VideoEncoder(
                width: source.width, height: source.height, frameRate: options.frameRate, bitrate: options.encoderBitrate,
                output: output)
        } catch {
            source.stop()
            throw error
        }
        let pipeline = Pipeline(id: id, stream: stream, display: display, queue: queue, source: source, encoder: encoder)
        do { try await pipeline.start() }
        catch {
            pipeline.stop()
            throw error
        }
        return pipeline
    }

    func start() async throws { try await source.start() }

    var size: (width: Int, height: Int) { (source.width, source.height) }

    /// False once capture has stopped, even if it stopped without saying so.
    var isCapturing: Bool { queue.sync { !stopped && source.isCapturing } }

    /// Encodes only while the session streams; capture and the encoder stay warm otherwise.
    func setStreaming(_ on: Bool) {
        queue.async { [self] in
            guard !stopped, on != streaming else { return }
            streaming = on
            if on {
                keyframePending = true
                if source.isCapturing, let lastPicture { encode(lastPicture, at: monotonicMicros()) }
                refreshTimer?.schedule(deadline: .now() + 1, repeating: .milliseconds(250), leeway: .milliseconds(10))
            } else {
                refreshTimer?.schedule(deadline: .distantFuture)
            }
        }
    }

    /// Encodes the newest picture as a keyframe now, so that a still screen does not leave the
    /// client waiting for the next change.
    func requestKeyframe() {
        queue.async { [self] in
            guard !stopped else { return }
            keyframePending = true
            if streaming, source.isCapturing, let lastPicture { encode(lastPicture, at: monotonicMicros()) }
        }
    }

    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            streaming = false
            refreshTimer?.cancel()
            refreshTimer = nil
            source.stop()
            encoder.invalidate()
            lastPicture = nil
        }
    }

    func waitUntilStopped() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        await source.waitUntilStopped()
    }

    private func captured(_ pixels: CVPixelBuffer, at micros: UInt64) {
        guard !stopped else { return }
        lastPicture = pixels
        guard streaming else { return }
        encode(pixels, at: micros)
    }

    private func encode(_ pixels: CVPixelBuffer, at micros: UInt64) {
        lastEncodedAt = monotonicMicros()
        encoder.encode(pixels, captureTimeMicros: micros, forceKeyframe: keyframePending)
        keyframePending = false
    }
}
