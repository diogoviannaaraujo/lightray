import CoreGraphics
import CoreVideo
import Foundation

/// Decoding for one video stream: a bounded decoder on a queue of its own, and the renderer its
/// pictures go to once there is one. It is created on the network queue the moment its stream
/// delivers a frame, so that no frame waits for a window. Every result carries the decoder's
/// epoch, and results from an epoch the decoder has since left are dropped.
///
/// Frames that arrive in a burst, after a Wi-Fi stall say, are all decoded, since each refers to
/// the one before, but only the newest is shown: the picture catches up at once instead of
/// replaying the stall.
final class StreamDecoder: @unchecked Sendable {
    private let worker: BoundedVideoDecoder

    // On the worker's queue.
    private var renderer: VideoRenderer?
    private var pending: (pixels: CVPixelBuffer, epoch: UInt64)?
    private var size: CGSize?
    /// Called on the decode queue with each result and its epoch, to report it to the endpoint.
    var onResult: ((VideoDecoder.Result, UInt64) -> Void)?
    /// Called on the decode queue when the picture's size changes.
    var onSize: ((CGSize, UInt64) -> Void)?
    /// Called on the decode queue with each picture.
    var onPicture: ((CVPixelBuffer, UInt64) -> Void)?

    init(stream: UInt8) {
        worker = BoundedVideoDecoder(stream: stream)
        worker.onResult = { [weak self] result, epoch, present in
            guard let self, worker.isCurrent(epoch) else { return }
            if case .picture(let pixels, _, _) = result {
                if let renderer {
                    if present { renderer.enqueue(pixels) }
                } else {
                    pending = (pixels, epoch)
                }
                let newSize = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
                if newSize != size {
                    size = newSize
                    onSize?(newSize, epoch)
                }
                onPicture?(pixels, epoch)
            }
            onResult?(result, epoch)
        }
    }

    var decoded: Int { worker.decoded }
    var dropped: Int { worker.dropped }
    var isActive: Bool { worker.isActive }
    func isCurrent(_ epoch: UInt64) -> Bool { worker.isCurrent(epoch) }
    func takeTimings() -> DecodeTimings { worker.takeTimings() }

    /// Queues a frame. Returns the identifier of a frame the queue gave up on, for the endpoint
    /// to report lost.
    @discardableResult
    func submit(_ frame: DeliveredFrame) -> UInt32? { worker.submit(frame) }

    func attach(_ renderer: VideoRenderer) {
        worker.queue.async { [self] in
            guard worker.isActive else { return }
            self.renderer = renderer
            if let pending, worker.isCurrent(pending.epoch) { renderer.enqueue(pending.pixels) }
            pending = nil
        }
    }

    func invalidate() {
        worker.cancel()
        worker.queue.async { [self] in
            renderer = nil
            pending = nil
        }
    }
}
