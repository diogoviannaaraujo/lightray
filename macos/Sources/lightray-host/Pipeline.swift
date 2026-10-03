import CoreVideo
import Foundation
import LightrayCore

/// Capture and encoding for one video stream showing one display. Each stream has its own, on a
/// queue of its own, so that nothing one display does reaches another (`docs/displays.md`).
final class Pipeline: @unchecked Sendable {
    let stream: UInt8
    let display: DisplayInfo
    private let queue: DispatchQueue
    private let source: FrameSource
    private let encoder: VideoEncoder
    var onFailure: ((String) -> Void)?

    // Owned by `queue`.
    private var lastPicture: CVPixelBuffer?
    private var keyframePending = true
    private var streaming = false

    private init(stream: UInt8, display: DisplayInfo, queue: DispatchQueue, source: FrameSource, encoder: VideoEncoder) {
        self.stream = stream
        self.display = display
        self.queue = queue
        self.source = source
        self.encoder = encoder
    }

    /// Starts capturing `display` and creates an encoder of its size. Throws if either cannot
    /// start, which is how a host finds the limit of its hardware.
    static func start(
        stream: UInt8, display: DisplayInfo, options: HostOptions, output: @escaping @Sendable (EncodedFrame) -> Void
    ) async throws -> Pipeline {
        let queue = DispatchQueue(label: "lightray.capture.\(stream)", qos: .userInteractive)
        let source: FrameSource
        if options.testPattern != nil {
            let pattern = TestPattern(
                width: display.width, height: display.height, frameRate: options.frameRate, variant: Int(display.id),
                queue: queue)
            pattern.start()
            source = pattern
        } else {
            let capture = ScreenCapture(queue: queue)
            try await capture.start(displayID: display.id, frameRate: options.frameRate, scale: options.scale)
            source = capture
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
        let pipeline = Pipeline(stream: stream, display: display, queue: queue, source: source, encoder: encoder)
        // Weak: a source can deliver one more frame after `stop`, when the pipeline may be gone.
        source.onFrame = { [weak pipeline] pixels, micros in pipeline?.captured(pixels, at: micros) }
        source.onFailure = { [weak pipeline] reason in pipeline?.onFailure?(reason) }
        return pipeline
    }

    var size: (width: Int, height: Int) { (source.width, source.height) }

    /// False once capture has stopped, even if it stopped without saying so.
    var isCapturing: Bool { source.isCapturing }

    /// Encodes only while the session streams; capture and the encoder stay warm otherwise.
    func setStreaming(_ on: Bool) {
        queue.async { [self] in
            if on, !streaming { keyframePending = true }
            streaming = on
        }
    }

    /// Encodes the newest picture as a keyframe now, so that a still screen does not leave the
    /// client waiting for the next change.
    func requestKeyframe() {
        queue.async { [self] in
            keyframePending = true
            if streaming, let lastPicture { encode(lastPicture, at: monotonicMicros()) }
        }
    }

    func stop() {
        source.stop()
        queue.async { [encoder] in encoder.invalidate() }
    }

    private func captured(_ pixels: CVPixelBuffer, at micros: UInt64) {
        lastPicture = pixels
        guard streaming else { return }
        encode(pixels, at: micros)
    }

    private func encode(_ pixels: CVPixelBuffer, at micros: UInt64) {
        encoder.encode(pixels, captureTimeMicros: micros, forceKeyframe: keyframePending)
        keyframePending = false
    }
}
