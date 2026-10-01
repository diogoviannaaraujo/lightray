import Dispatch
import Testing

@testable import LightrayCore

@Test func memoryReservationsRollBackAndRelease() {
    let local = MemoryBudget(limit: 100)
    let shared = MemoryBudget(limit: 50)
    #expect(local.reserve(60, sharing: shared) == nil)
    #expect(local.usedBytes == 0 && shared.usedBytes == 0)
    var held: MemoryReservation? = local.reserve(40, sharing: shared)
    #expect(held != nil && local.usedBytes == 40 && shared.usedBytes == 40)
    #expect(local.reserve(20, sharing: shared) == nil)
    held = nil
    #expect(local.usedBytes == 0 && shared.usedBytes == 0)
    #expect(local.reserve(-1) == nil)
    DispatchQueue.concurrentPerform(iterations: 100) { _ in
        let lease = local.reserve(10)
        withExtendedLifetime(lease) { #expect(local.usedBytes <= local.limit) }
    }
    #expect(local.usedBytes == 0 && local.peakBytes <= local.limit)
}

@Test func videoBudgetIsSharedAndFollowsDeliveredFrames() throws {
    let shared = MemoryBudget(limit: 1600)
    let first = VideoReceiver(stream: 1, sharedBudget: shared)
    let second = VideoReceiver(stream: 16, sharedBudget: shared)
    let bytes = frame(idr: true, size: 100)
    for part in fragments(frameID: 1, frame: bytes, stream: 1) { first.receive(part, now: 1, budget: 50_000) }
    var held = first.takeFrames()
    #expect(held.count == 1 && shared.usedBytes > 0)
    for part in fragments(frameID: 1, frame: bytes, stream: 16) { second.receive(part, now: 1, budget: 50_000) }
    #expect(second.takeFrames().isEmpty && second.stats.memoryLimitDrops > 0)
    #expect(shared.usedBytes <= shared.limit)
    held.removeAll()
    #expect(shared.usedBytes == 0)
    for part in fragments(frameID: 1, frame: bytes, stream: 16) { second.receive(part, now: 2, budget: 50_000) }
    #expect(second.takeFrames().count == 1)
    #expect(shared.usedBytes == 0)
}

@Test func incompleteVideoFramesCannotExceedTheBudget() {
    let budget = MemoryBudget(limit: 2500)
    var receiver: VideoReceiver? = VideoReceiver(stream: 1, memoryBudget: budget)
    for id in UInt32(1)...100 {
        receiver!.receive(MediaFragment(stream: 1, flags: 0, frameID: id, index: 0, count: 2, stride: 200, payload: Bytes(repeating: 0, count: 200)[...]), now: 1, budget: 50_000)
        #expect(budget.usedBytes <= budget.limit)
    }
    #expect(receiver!.stats.memoryLimitDrops > 0)
    receiver = nil
    #expect(budget.usedBytes == 0)
}

@Test func reliableMetadataAndPayloadShareTheConnectionBudget() {
    let shared = MemoryBudget(limit: 800)
    var first: ReliableReceiver? = ReliableReceiver(stream: 4, sharedBudget: shared)
    let second = ReliableReceiver(stream: 5, sharedBudget: shared)
    let part = ReliableSegment(stream: 4, msgSeq: 0, segIndex: 0, segCount: 2, payload: Bytes(repeating: 1, count: 100))
    #expect(first!.receive(part) == .accepted(ack: false, deliver: []))
    #expect(second.receive(part) == .discarded)
    #expect(shared.usedBytes <= shared.limit)
    first = nil
    #expect(shared.usedBytes == 0)
    #expect(second.receive(part) == .accepted(ack: false, deliver: []))
    #expect(second.receive(ReliableSegment(stream: 5, msgSeq: 0, segIndex: 1, segCount: 2, payload: [2])) == .accepted(ack: true, deliver: [Bytes(repeating: 1, count: 100) + [2]]))
    #expect(shared.usedBytes == 0)
}

@Test func reliableRejectsInvalidSegmentsBeforeAllocating() {
    let budget = MemoryBudget(limit: 1000)
    let receiver = ReliableReceiver(stream: 4, memoryBudget: budget)
    for (index, count) in [(UInt16(0), UInt16(0)), (2, 2), (0, .max)] {
        #expect(receiver.receive(ReliableSegment(stream: 4, msgSeq: 0, segIndex: index, segCount: count, payload: [1])) == .discarded)
        #expect(budget.usedBytes == 0)
    }
    #expect(receiver.receive(ReliableSegment(stream: 4, msgSeq: 0, segIndex: 0, segCount: 8192, payload: [1])) == .discarded)
    #expect(budget.usedBytes == 0)
}

@Test func futureReliableMessagesLeaveRoomForTheOrderingGap() {
    let budget = MemoryBudget(limit: 4 << 20)
    let receiver = ReliableReceiver(stream: 4, memoryBudget: budget)
    let future = Bytes(repeating: 7, count: 500_000)
    #expect(receiver.receive(ReliableSegment(stream: 4, msgSeq: 1, segIndex: 0, segCount: 1, payload: future)) == .accepted(ack: true, deliver: []))
    #expect(receiver.receive(ReliableSegment(stream: 4, msgSeq: 2, segIndex: 0, segCount: 1, payload: future)) == .discarded)
    let missing = Bytes(repeating: 1, count: ReliableReceiver.maxMessageBytes)
    #expect(receiver.receive(ReliableSegment(stream: 4, msgSeq: 0, segIndex: 0, segCount: 1, payload: missing)) == .accepted(ack: true, deliver: [missing, future]))
    #expect(budget.usedBytes == 0)
}

@Test func reliableSenderBoundsAndReleasesRetainedPayloads() {
    let budget = MemoryBudget(limit: 1000)
    let sender = ReliableSender(stream: 4, memoryBudget: budget)
    #expect(!sender.enqueue([1], maxSegmentPayload: 0))
    #expect(!sender.enqueue(Bytes(repeating: 0, count: ReliableReceiver.maxMessageBytes + 1), maxSegmentPayload: 200))
    #expect(sender.enqueue(Bytes(repeating: 0, count: 100), maxSegmentPayload: 200))
    #expect(!sender.enqueue(Bytes(repeating: 0, count: 200), maxSegmentPayload: 200))
    sender.acknowledge(0)
    #expect(budget.usedBytes == 0)
}
