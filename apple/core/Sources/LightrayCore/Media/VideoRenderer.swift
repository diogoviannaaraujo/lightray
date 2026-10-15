import AVFoundation

/// Shows decoded pictures, each at once, aspect-fit. A view adds `displayLayer` to its own layer
/// and keeps it the view's size.
///
/// It is made on the main thread, which alone uses `displayLayer`; after that only `enqueue`, on
/// one decode queue, uses the receiver.
public final class VideoRenderer: @unchecked Sendable {
    public let displayLayer: AVSampleBufferDisplayLayer
    /// The layer's renderer only takes pictures through a synchronizer, whose clock runs on host
    /// time; every picture is marked to show at once regardless.
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let receiver: AVSampleBufferVideoRenderer.Receiver

    @MainActor public init() {
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        receiver = synchronizer.sampleBufferReceiver(adding: displayLayer.sampleBufferRenderer)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        synchronizer.setRate(1, time: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    /// Shows a decoded picture at once. Safe from any one serial queue.
    public func enqueue(_ pixels: CVPixelBuffer) {
        // The decoder never writes to a picture it has handed out, so a read-only view of it is
        // sound even though others hold it too.
        nonisolated(unsafe) let shared = pixels
        var picture = CMReadySampleBuffer(
            pixelBuffer: CVReadOnlyPixelBuffer(unsafeBuffer: shared),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()))
        picture.sampleAttachments.displayImmediately = true
        let sample = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(picture)
        switch receiver.enqueueImmediately(sample) {
        case .cancelledDueToFlushRequiredToResume, .cancelledDueToError:
            receiver.flush()
            _ = receiver.enqueueImmediately(sample)
        default:
            break
        }
    }
}
