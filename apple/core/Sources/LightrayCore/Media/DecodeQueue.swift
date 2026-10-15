import Foundation

/// A bounded, single-consumer decode mailbox; a lost dependency requires a new IDR.
public final class DecodeQueue: @unchecked Sendable {
    public struct Work: Sendable {
        public let frame: DeliveredFrame
        public let epoch: UInt64
        fileprivate let ticket: UInt64
    }

    public enum Poll {
        case frame(Work)
        case needsKeyframe(UInt32, epoch: UInt64)
        case idle
    }

    public struct Completion {
        public let report: Bool
        public let present: Bool
        public let epoch: UInt64
    }

    public let maxFrames: Int
    public let maxBytes: Int
    public let maxAgeMicros: UInt64
    private let lock = NSLock()
    private var enabled = true
    private var epoch: UInt64 = 0
    private var nextTicket: UInt64 = 0
    private var pending: [DeliveredFrame] = []
    private var active: Work?
    private var waitingForKeyframe = true
    private var configuration: UInt32?
    private var dropped = 0

    public init(maxFrames: Int = 3, maxBytes: Int = 32 << 20, maxAgeMicros: UInt64 = 100_000) {
        precondition(maxFrames > 0 && maxBytes > 0)
        self.maxFrames = maxFrames
        self.maxBytes = maxBytes
        self.maxAgeMicros = maxAgeMicros
    }

    public var isActive: Bool { lock.withLock { enabled } }
    public var droppedFrames: Int { lock.withLock { dropped } }
    public var retainedBytes: Int { lock.withLock { bytes } }
    public var retainedFrames: Int { lock.withLock { pending.count + (active == nil ? 0 : 1) } }
    public func isCurrent(_ token: UInt64) -> Bool { lock.withLock { enabled && epoch == token } }

    private var bytes: Int { pending.reduce(active?.frame.bytes.count ?? 0) { $0 + $1.bytes.count } }

    private func expired(_ frame: DeliveredFrame, now: UInt64) -> Bool {
        now >= frame.completedAt && now - frame.completedAt > maxAgeMicros
    }

    private func loseChain() {
        dropped += pending.count
        pending.removeAll()
        epoch &+= 1
        waitingForKeyframe = true
        configuration = nil
    }

    /// Returns the lost frame to report to the endpoint, at most once while awaiting an IDR.
    @discardableResult
    public func submit(_ frame: DeliveredFrame, now: UInt64) -> UInt32? {
        lock.withLock {
            guard enabled else { return nil }
            let keyframe = frame.header.frameType == .idr
            if keyframe {
                // An IDR supersedes queued references and invalidates callbacks from the preceding configuration.
                loseChain()
            } else if waitingForKeyframe {
                dropped += 1
                return nil
            }
            let wrongConfiguration = !keyframe && configuration != frame.header.configGeneration
            if expired(frame, now: now) || wrongConfiguration || pending.count + (active == nil ? 0 : 1) >= maxFrames || frame.bytes.count > maxBytes - bytes {
                let shouldReport = keyframe || !waitingForKeyframe
                loseChain()
                dropped += 1
                return shouldReport ? frame.frameID : nil
            }
            waitingForKeyframe = false
            configuration = frame.header.configGeneration
            pending.append(frame)
            return nil
        }
    }

    public func poll(now: UInt64) -> Poll {
        lock.withLock {
            guard enabled, active == nil, let frame = pending.first else { return .idle }
            if expired(frame, now: now) {
                loseChain()
                return .needsKeyframe(frame.frameID, epoch: epoch)
            }
            pending.removeFirst()
            let work = Work(frame: frame, epoch: epoch, ticket: nextTicket)
            nextTicket &+= 1
            active = work
            return .frame(work)
        }
    }

    public func finish(_ work: Work, succeeded: Bool) -> Completion {
        lock.withLock {
            guard active?.ticket == work.ticket else { return Completion(report: false, present: false, epoch: epoch) }
            active = nil
            guard enabled, work.epoch == epoch else { return Completion(report: false, present: false, epoch: epoch) }
            if !succeeded {
                loseChain()
                // This failure still belongs to the live session, even though dependent frames were discarded.
                return Completion(report: true, present: false, epoch: epoch)
            }
            return Completion(report: true, present: pending.isEmpty, epoch: epoch)
        }
    }

    /// The in-flight buffer remains charged until its consumer finishes; pending work is released immediately.
    public func cancel() {
        lock.withLock {
            enabled = false
            loseChain()
        }
    }
}
