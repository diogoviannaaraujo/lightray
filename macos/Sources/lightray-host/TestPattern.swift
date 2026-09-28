import CoreVideo
import Foundation
import LightrayMac

/// A synthetic source in place of the screen: a moving bar over a gradient, at a fixed rate.
/// It needs no Screen Recording permission, which makes it the way to test the transport alone.
/// `variant` 1 and 2 differ in colour and direction, to tell two displays apart.
final class TestPattern: FrameSource {
    let queue: DispatchQueue
    let width: Int
    let height: Int
    private let frameRate: Int
    private let variant: Int
    private var pool: CVPixelBufferPool?
    private var timer: DispatchSourceTimer?
    private var frame = 0
    var onFrame: ((CVPixelBuffer, UInt64) -> Void)?
    var onFailure: ((String) -> Void)?

    init(width: Int, height: Int, frameRate: Int, variant: Int = 1, queue: DispatchQueue) {
        self.width = width & ~1
        self.height = height & ~1
        self.frameRate = frameRate
        self.variant = variant
        self.queue = queue
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: self.width,
            kCVPixelBufferHeightKey: self.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .microseconds(1_000_000 / frameRate), leeway: .microseconds(500))
        timer.setEventHandler { [unowned self] in draw() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func draw() {
        guard let pool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let pixels = buffer else { return }
        CVPixelBufferLockBaseAddress(pixels, [])
        let luma = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let bar = variant == 1 ? (frame * 8) % width : width - 1 - (frame * 8) % width
        for y in 0..<height {
            let row = luma + y * lumaStride
            for x in 0..<width {
                row[x] = abs(x - bar) < 40 ? 235 : UInt8(16 + (x + y) * 200 / (width + height))
            }
        }
        // A patch of noise, which does not compress, so that frames are large enough to span
        // many datagrams.
        var seed = UInt32(truncatingIfNeeded: frame &* 2_654_435_761)
        for y in (height / 3)..<(height / 3 + height / 6) {
            let row = luma + y * lumaStride
            for x in (width / 3)..<(width / 3 + width / 6) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                row[x] = UInt8(16 + (seed >> 24) % 220)
            }
        }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(pixels, 1)!.assumingMemoryBound(to: UInt8.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1)
        for y in 0..<height / 2 {
            let row = chroma + y * chromaStride
            for x in 0..<width / 2 {
                let u = UInt8(64 + x * 128 / (width / 2))
                let v = UInt8(64 + y * 128 / (height / 2))
                row[2 * x] = variant == 1 ? u : v
                row[2 * x + 1] = variant == 1 ? v : u
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        frame += 1
        onFrame?(pixels, monotonicMicros())
    }
}
