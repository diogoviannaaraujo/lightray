import Dispatch
import Foundation
import VideoToolbox

/// One drain task per stream, with bounded input and epoch-tagged results; configure callbacks before submitting frames.
public final class BoundedVideoDecoder: @unchecked Sendable {
    public let queue: DispatchQueue
    public var onResult: ((VideoDecoder.Result, UInt64, Bool) -> Void)?
    private let mailbox: DecodeQueue
    private let decoder = VideoDecoder()
    private let decodeFrame: (DeliveredFrame) -> VideoDecoder.Result
    private let now: () -> UInt64
    private let lock = NSLock()
    private var scheduled = false
    private var decodedCount = 0
    private var timings = DecodeTimings()

    public init(stream: UInt8, mailbox: DecodeQueue = DecodeQueue(), now: @escaping () -> UInt64 = monotonicMicros, decode: ((DeliveredFrame) -> VideoDecoder.Result)? = nil) {
        queue = DispatchQueue(label: "lightray.decode.\(stream)", qos: .userInteractive)
        self.mailbox = mailbox
        self.now = now
        let backend = decoder
        decodeFrame = decode ?? { backend.decode($0) }
    }

    public var decoded: Int { lock.withLock { decodedCount } }
    public var dropped: Int { mailbox.droppedFrames }
    public var retainedBytes: Int { mailbox.retainedBytes }
    public var isActive: Bool { mailbox.isActive }
    public func takeTimings() -> DecodeTimings {
        lock.withLock {
            let result = timings
            timings = DecodeTimings()
            return result
        }
    }
    public func isCurrent(_ epoch: UInt64) -> Bool { mailbox.isCurrent(epoch) }

    @discardableResult
    public func submit(_ frame: DeliveredFrame) -> UInt32? {
        var schedule = false
        let lost = lock.withLock {
            let lost = mailbox.submit(frame, now: now())
            if mailbox.isActive && !scheduled {
                scheduled = true
                schedule = true
            }
            return lost
        }
        if schedule { queue.async { [self] in drain() } }
        return lost
    }

    public func cancel() {
        lock.withLock { mailbox.cancel() }
        queue.async { [self] in decoder.invalidate() }
    }

    private func drain() {
        let next = lock.withLock {
            let next = mailbox.poll(now: now())
            if case .idle = next { scheduled = false }
            return next
        }
        switch next {
        case .idle:
            return
        case .needsKeyframe(let id, let epoch):
            onResult?(.failed(frameID: id, status: kVTVideoDecoderBadDataErr), epoch, false)
        case .frame(let work):
            let started = now()
            let result = decodeFrame(work.frame)
            let finished = now()
            let succeeded: Bool
            if case .picture = result { succeeded = true } else { succeeded = false }
            let completion = mailbox.finish(work, succeeded: succeeded)
            if completion.report {
                if succeeded {
                    lock.withLock {
                        decodedCount += 1
                        timings.record(completedAt: work.frame.completedAt, decodeStarted: started, decodeFinished: finished, hostTimings: work.frame.header.hostTimings)
                    }
                }
                onResult?(result, completion.epoch, completion.present)
            }
        }
        // Keep one drain scheduled, but let attachment and cancellation run between frames.
        queue.async { [self] in drain() }
    }
}
