import Testing
@testable import LightrayCore

private func queuedFrame(_ id: UInt32, key: Bool = false, generation: UInt32 = 0, size: Int = 10, at: UInt64 = 0) -> DeliveredFrame {
    let header = FrameHeader(frameType: key ? .idr : .predicted, refKind: key ? .none : .previous, configGeneration: generation, captureTimeMicros: 0)
    return DeliveredFrame(frameID: id, header: header, bytes: Bytes(repeating: 0, count: size), payloadOffset: 0, completedAt: at)
}

@Test func decodeQueueBoundsAndRecoversWithIDR() throws {
    let queue = DecodeQueue(maxFrames: 3, maxBytes: 30)
    #expect(queue.submit(queuedFrame(1, key: true), now: 0) == nil)
    guard case .frame(let work) = queue.poll(now: 0) else { Issue.record("missing IDR"); return }
    queue.submit(queuedFrame(2), now: 0)
    queue.submit(queuedFrame(3), now: 0)
    #expect(queue.retainedFrames == 3 && queue.retainedBytes == 30)
    #expect(queue.submit(queuedFrame(4), now: 0) == 4)
    for id: UInt32 in 5...1000 { #expect(queue.submit(queuedFrame(id), now: 0) == nil) }
    #expect(queue.retainedFrames == 1 && queue.retainedBytes == 10)
    #expect(!queue.finish(work, succeeded: true).report)
    queue.submit(queuedFrame(1001, key: true), now: 0)
    guard case .frame(let next) = queue.poll(now: 0) else { Issue.record("missing recovery IDR"); return }
    let completion = queue.finish(next, succeeded: true)
    #expect(completion.report && completion.present && queue.isCurrent(completion.epoch))
    #expect(queue.retainedBytes == 0)
}

@Test func decodeQueueRejectsStaleAndChangedConfiguration() {
    let queue = DecodeQueue(maxAgeMicros: 100)
    #expect(queue.submit(queuedFrame(1, key: true), now: 101) == 1)
    queue.submit(queuedFrame(2, key: true, generation: 1), now: 0)
    #expect(queue.submit(queuedFrame(3, generation: 2), now: 0) == 3)
    #expect(queue.retainedFrames == 0)
    queue.submit(queuedFrame(4, key: true), now: 0)
    guard case .needsKeyframe(let id, let epoch) = queue.poll(now: 101) else { Issue.record("expired work decoded"); return }
    #expect(id == 4 && queue.isCurrent(epoch))
}

@Test func decodeQueueFailureAndCancellationInvalidateCallbacks() {
    let queue = DecodeQueue()
    queue.submit(queuedFrame(1, key: true), now: 0)
    guard case .frame(let work) = queue.poll(now: 0) else { Issue.record("missing work"); return }
    queue.submit(queuedFrame(2), now: 0)
    let failure = queue.finish(work, succeeded: false)
    #expect(failure.report && !failure.present && queue.isCurrent(failure.epoch))
    #expect(queue.retainedBytes == 0)
    queue.submit(queuedFrame(3), now: 0)
    #expect(queue.retainedFrames == 0)
    queue.submit(queuedFrame(4, key: true), now: 0)
    guard case .frame(let next) = queue.poll(now: 0) else { Issue.record("missing new work"); return }
    #expect(!queue.finish(work, succeeded: true).report)
    #expect(queue.retainedFrames == 1)
    queue.cancel()
    #expect(!queue.isCurrent(next.epoch) && !queue.isActive && queue.retainedBytes == 10)
    #expect(!queue.finish(next, succeeded: true).report)
    #expect(queue.retainedBytes == 0)
}

@Test func newerIDRSupersedesActiveDecodeWithoutExceedingByteLimit() {
    let queue = DecodeQueue(maxFrames: 3, maxBytes: 25)
    queue.submit(queuedFrame(1, key: true), now: 0)
    guard case .frame(let work) = queue.poll(now: 0) else { Issue.record("missing work"); return }
    queue.submit(queuedFrame(2), now: 0)
    queue.submit(queuedFrame(3, key: true), now: 0)
    #expect(queue.retainedBytes == 20)
    #expect(!queue.finish(work, succeeded: true).report)
    #expect(queue.submit(queuedFrame(4, size: 20), now: 0) == 4)
    #expect(queue.retainedBytes == 0)
}
