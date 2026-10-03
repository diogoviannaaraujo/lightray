import CoreGraphics
import CoreVideo
import Foundation

/// Decoding for one video stream, on a queue of its own. It is created on the network queue the
/// moment its stream delivers a frame, so that no frame waits for a window; pictures reach the
/// renderer once there is one.
///
/// Frames that arrive in a burst, after a Wi-Fi stall say, are all decoded, since each refers to
/// the one before, but only the newest is shown: the picture catches up at once instead of
/// replaying the stall.
final class StreamDecoder: @unchecked Sendable {
    let stream: UInt8
    let queue: DispatchQueue
    private let decoder = VideoDecoder()
    private let lock = NSLock()
    private var decodedCount = 0
    private var waiting = 0

    // On `queue`.
    private var renderer: VideoRenderer?
    private var pending: CVPixelBuffer?
    private var size: CGSize?
    /// Called on `queue` with each result, to report it to the endpoint.
    var onResult: ((VideoDecoder.Result) -> Void)?
    /// Called on `queue` when the picture's size changes.
    var onSize: ((CGSize) -> Void)?
    /// Called on `queue` with each picture.
    var onPicture: ((CVPixelBuffer) -> Void)?

    init(stream: UInt8) {
        self.stream = stream
        queue = DispatchQueue(label: "lightray.decode.\(stream)", qos: .userInteractive)
    }

    var decoded: Int { lock.withLock { decodedCount } }

    func submit(_ frame: DeliveredFrame) {
        lock.withLock { waiting += 1 }
        queue.async { [self] in decode(frame) }
    }

    func attach(_ renderer: VideoRenderer) {
        queue.async { [self] in
            self.renderer = renderer
            if let pending { renderer.enqueue(pending) }
            pending = nil
        }
    }

    func invalidate() {
        queue.async { [self] in
            decoder.invalidate()
            renderer = nil
        }
    }

    private func decode(_ frame: DeliveredFrame) {
        let result = decoder.decode(frame)
        let newerWaiting = lock.withLock {
            waiting -= 1
            return waiting > 0
        }
        if case .picture(let pixels, _, _) = result {
            lock.withLock { decodedCount += 1 }
            if let renderer {
                if !newerWaiting { renderer.enqueue(pixels) }
            } else {
                pending = pixels
            }
            let newSize = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
            if newSize != size {
                size = newSize
                onSize?(newSize)
            }
            onPicture?(pixels)
        }
        onResult?(result)
    }
}
