import LightrayCore

/// When a gap becomes a loss and how often to ask again. A seam: the defaults
/// are the plan's, and a smarter policy plugs in here.
struct NackPolicy {
    var reorderWindow: Interval
    var retryFloor: Interval

    /// A gap is not a loss until the reorder window has passed.
    func firstDue(firstArrival: Instant) -> Instant { firstArrival + reorderWindow }
    /// Retry every max(1.5·srtt, floor).
    func retryDue(lastAttempt: Instant, srtt: Interval) -> Instant {
        lastAttempt + retryPeriod(srtt: srtt)
    }

    func retryPeriod(srtt: Interval) -> Interval {
        Interval(nanos: max(UInt64(Double(srtt.nanos) * 1.5), retryFloor.nanos))
    }
}

/// Reassembles fragmented frames and schedules the NACKs for what is missing.
///
/// Every fragment carries `stride`, so any fragment can be placed at
/// `index × stride` in one contiguous buffer the moment it arrives — including a
/// last fragment that arrives before any other.
final class Reassembler {
    struct Slot {
        var active = false
        /// The frame was completed or given up on. The slot stays so late
        /// retransmissions cannot resurrect it, but its buffer is already gone.
        var consumed = false
        var frameID: UInt32 = 0
        var buffer: UnsafeMutableRawBufferPointer? = nil
        var bits = Bitset()
        var count = 0
        var stride = 0
        /// Known only once the last fragment arrives.
        var totalBytes = -1
        var received = 0
        var highestIndex = -1
        var firstArrival: Instant = .zero
        var lastArrival: Instant = .zero
        var lastNack: Instant = .zero
        var nackAttempts = 0
        var deadline: Instant = .zero
        var keyframe = false
    }

    /// A frame id that was skipped entirely: no fragment of it has arrived, so
    /// its fragment count is unknown and the NACK asks for the whole frame.
    struct MissingFrame {
        var firstSeen: Instant
        var lastNack: Instant = .zero
        var attempts = 0
        var deadline: Instant
    }

    let stream: UInt8
    private let pool: BufferPool
    private var slots: [Slot]
    private var missing: [UInt32: MissingFrame] = [:]
    private(set) var highestFrameID: UInt32 = 0
    private(set) var sawAnyFrame = false
    var stats = StreamStats()

    init(stream: UInt8, pool: BufferPool, maxFramesInFlight: Int) {
        self.stream = stream
        self.pool = pool
        self.slots = [Slot](repeating: Slot(), count: max(1, maxFramesInFlight))
    }

    deinit { flush() }

    enum Acceptance {
        case duplicate
        case progress
        case complete(Int)
        case rejected
    }

    /// Places a fragment. `deadline` is measured from the frame's first arrival.
    func accept(_ header: FragmentHeader, payload: RawSpan, at now: Instant,
                deadline: Interval) -> Acceptance {
        stats.fragmentsReceived &+= 1

        // A frame already completed or given up on must not restart a slot: a
        // NACK answered just after the frame was consumed would otherwise be
        // reassembled and delivered twice.
        if let i = slotIndex(header.frameID), slots[i].consumed {
            stats.fragmentsDuplicate &+= 1
            return .duplicate
        }
        if sawAnyFrame, serialGreater(highestFrameID, header.frameID), slotIndex(header.frameID) == nil,
           missing[header.frameID] == nil {
            return .duplicate
        }

        let index: Int
        if let i = slotIndex(header.frameID) {
            index = i
        } else {
            guard let i = allocateSlot(for: header, at: now, deadline: deadline) else { return .rejected }
            index = i
        }

        guard slots[index].count == Int(header.count), slots[index].stride == Int(header.stride) else {
            // A mid-frame change of either is a protocol violation; drop it.
            return .rejected
        }
        guard let buffer = slots[index].buffer else { return .rejected }

        let offset = header.payloadOffset
        let length = payload.byteCount
        guard offset >= 0, offset + length <= buffer.count else { return .rejected }

        guard slots[index].bits.testAndSet(Int(header.index)) else {
            stats.fragmentsDuplicate &+= 1
            return .duplicate
        }
        payload.withUnsafeBytes { src in
            if length > 0 {
                UnsafeMutableRawBufferPointer(rebasing: buffer[offset..<(offset + length)]).copyMemory(from: src)
            }
        }
        slots[index].received += 1
        slots[index].lastArrival = now
        if Int(header.index) > slots[index].highestIndex { slots[index].highestIndex = Int(header.index) }
        if header.index == header.count - 1 {
            slots[index].totalBytes = offset + length
        }
        if header.flags.contains(.keyframe) { slots[index].keyframe = true }

        // The frame id is now accounted for, so it is no longer "whole-frame missing".
        missing[header.frameID] = nil

        if sawAnyFrame {
            if serialGreater(header.frameID, highestFrameID) {
                // Every id between the last one seen and this one produced bytes
                // at the sender but nothing here: those are whole-frame losses.
                var id = highestFrameID &+ 1
                while serialGreater(header.frameID, id) {
                    if slotIndex(id) == nil, missing[id] == nil {
                        missing[id] = MissingFrame(firstSeen: now, deadline: now + deadline)
                        stats.framesIncomplete &+= 0   // counted when it actually expires
                    }
                    id &+= 1
                }
                highestFrameID = header.frameID
            }
        } else {
            sawAnyFrame = true
            highestFrameID = header.frameID
        }

        if slots[index].received == slots[index].count, slots[index].totalBytes >= 0 {
            return .complete(index)
        }
        return .progress
    }

    struct Completed {
        var frameID: UInt32
        var buffer: UnsafeMutableRawBufferPointer
        var byteCount: Int
        var firstArrival: Instant
        var keyframe: Bool
    }

    /// Hands the completed frame's buffer to the caller and frees the slot. The
    /// caller owns the buffer until it returns it with `recycle`.
    func takeCompleted(_ index: Int) -> Completed? {
        guard slots[index].active, let buffer = slots[index].buffer, slots[index].totalBytes >= 0
        else { return nil }
        let out = Completed(frameID: slots[index].frameID, buffer: buffer,
                            byteCount: slots[index].totalBytes,
                            firstArrival: slots[index].firstArrival,
                            keyframe: slots[index].keyframe)
        slots[index].consumed = true
        slots[index].buffer = nil
        stats.framesCompleted &+= 1
        return out
    }

    func recycle(_ buffer: UnsafeMutableRawBufferPointer) { pool.giveBackLarge(buffer) }

    /// Frames whose deadline has passed while still incomplete. The caller turns
    /// each into a `.frameGap`, which is the cue for audio concealment.
    func expire(at now: Instant) -> [UInt32] {
        var gone: [UInt32] = []
        for i in 0..<slots.count where slots[i].active && !slots[i].consumed && now >= slots[i].deadline {
            gone.append(slots[i].frameID)
            if let b = slots[i].buffer { pool.giveBackLarge(b) }
            slots[i].consumed = true
            slots[i].buffer = nil
            stats.framesIncomplete &+= 1
        }
        for (id, m) in missing where now >= m.deadline {
            gone.append(id)
            missing[id] = nil
            stats.framesIncomplete &+= 1
        }
        return gone
    }

    /// NACK entries that are due now, newest frame first so the most useful
    /// requests get into a datagram even if it fills up.
    ///
    /// Only indices *below* the highest one received count as gaps. A frame the
    /// pacer is still spreading across its interval has plenty of indices that
    /// have simply not been sent yet, and NACKing those would turn every paced
    /// IDR into a retransmit storm. The tail above the highest index is covered
    /// by a separate timer, which only matters while the last fragment is
    /// missing — once it arrives, every hole is a gap.
    func collectNacks(at now: Instant, srtt: Interval, policy: NackPolicy, limit: Int) -> [NackEntry] {
        // The loop asks on every turn, and on a clean link there is never
        // anything outstanding, so this must not allocate to say "nothing".
        guard hasOutstandingFrames else { return [] }
        var out: [NackEntry] = []
        var indices = (0..<slots.count).filter { slots[$0].active && !slots[$0].consumed }
        indices.sort { serialGreater(slots[$0].frameID, slots[$1].frameID) }
        for i in indices {
            guard out.count < limit else { break }
            let due = slots[i].nackAttempts == 0
                ? policy.firstDue(firstArrival: slots[i].lastArrival)
                : policy.retryDue(lastAttempt: slots[i].lastNack, srtt: srtt)
            guard now >= due else { continue }
            let ceiling = slots[i].highestIndex
            var emitted = false
            slots[i].bits.forEachClearRun { first, count in
                guard out.count < limit, first < ceiling else { return }
                let capped = min(count, ceiling - first)
                out.append(NackEntry(frameID: slots[i].frameID, first: UInt16(first), count: UInt16(capped)))
                emitted = true
            }
            // Tail loss: the last fragment never arrived, and nothing new has
            // arrived for a retry period, so the sender has moved on.
            if !slots[i].bits[slots[i].count - 1], ceiling >= 0, out.count < limit,
               now - slots[i].lastArrival >= policy.retryPeriod(srtt: srtt) {
                let first = ceiling + 1
                if first < slots[i].count {
                    out.append(NackEntry(frameID: slots[i].frameID, first: UInt16(first),
                                         count: UInt16(slots[i].count - first)))
                    emitted = true
                }
            }
            if emitted {
                slots[i].lastNack = now
                slots[i].nackAttempts += 1
            }
        }
        for (id, m) in missing where out.count < limit {
            let due = m.attempts == 0 ? policy.firstDue(firstArrival: m.firstSeen)
                                      : policy.retryDue(lastAttempt: m.lastNack, srtt: srtt)
            guard now >= due else { continue }
            // count == 0: the whole frame, because its fragment count is unknown.
            out.append(NackEntry(frameID: id, first: 0, count: 0))
            missing[id]?.lastNack = now
            missing[id]?.attempts += 1
        }
        return out
    }

    /// True while any frame is still being assembled or is listed as missing.
    var hasOutstandingFrames: Bool {
        if !missing.isEmpty { return true }
        return slots.contains { $0.active && !$0.consumed }
    }

    /// The earliest moment any NACK could become due, for `nextTimeout`.
    func nextNackDeadline(srtt: Interval, policy: NackPolicy) -> Instant? {
        guard hasOutstandingFrames else { return nil }
        var earliest: Instant?
        func consider(_ t: Instant) {
            if earliest == nil || t < earliest! { earliest = t }
        }
        for s in slots where s.active && !s.consumed {
            consider(s.nackAttempts == 0 ? policy.firstDue(firstArrival: s.lastArrival)
                                         : policy.retryDue(lastAttempt: s.lastNack, srtt: srtt))
            consider(s.deadline)
        }
        for (_, m) in missing {
            consider(m.attempts == 0 ? policy.firstDue(firstArrival: m.firstSeen)
                                     : policy.retryDue(lastAttempt: m.lastNack, srtt: srtt))
            consider(m.deadline)
        }
        return earliest
    }

    /// Drops all in-flight state and returns the buffers. Both sides do this on
    /// a resume: every partial frame is stale, because a resume forces an IDR.
    func flush() {
        for i in 0..<slots.count {
            if let b = slots[i].buffer { pool.giveBackLarge(b) }
            slots[i] = Slot()
        }
        missing.removeAll(keepingCapacity: true)
    }

    var framesInFlight: Int { slots.count { $0.active && !$0.consumed } }

    func slotsHaveOlder(_ frameID: UInt32) -> Bool {
        slots.contains { $0.active && !$0.consumed && serialGreater(frameID, $0.frameID) }
    }

    func missingHasOlder(_ frameID: UInt32) -> Bool {
        missing.keys.contains { serialGreater(frameID, $0) }
    }
    var pendingNackCount: Int { missing.count }

    private func slotIndex(_ frameID: UInt32) -> Int? {
        slots.firstIndex { $0.active && $0.frameID == frameID }
    }

    private func oldestIndex(where predicate: (Slot) -> Bool) -> Int? {
        var best: Int?
        for i in 0..<slots.count where slots[i].active && predicate(slots[i]) {
            if best == nil || serialGreater(slots[best!].frameID, slots[i].frameID) { best = i }
        }
        return best
    }

    private func allocateSlot(for header: FragmentHeader, at now: Instant, deadline: Interval) -> Int? {
        var target = slots.firstIndex { !$0.active }
        // A consumed slot holds nothing but a frame id, so drop the oldest of
        // those before touching a frame still being assembled.
        if target == nil, let consumed = oldestIndex(where: { $0.consumed }) {
            slots[consumed] = Slot()
            target = consumed
        }
        if target == nil {
            // Evict the oldest frame, which is also the one closest to its deadline.
            var oldest = 0
            for i in 1..<slots.count where serialGreater(slots[oldest].frameID, slots[i].frameID) { oldest = i }
            if let b = slots[oldest].buffer { pool.giveBackLarge(b) }
            stats.framesIncomplete &+= 1
            slots[oldest] = Slot()
            target = oldest
        }
        guard let i = target else { return nil }
        // count × stride is an upper bound; the exact size arrives with the last fragment.
        let capacity = Int(header.count) * Int(header.stride)
        guard capacity > 0, capacity <= 64 << 20 else { return nil }
        var slot = Slot()
        slot.active = true
        slot.frameID = header.frameID
        slot.buffer = pool.takeLarge(capacity)
        slot.bits.reset(capacity: Int(header.count))
        slot.count = Int(header.count)
        slot.stride = Int(header.stride)
        slot.firstArrival = now
        slot.lastArrival = now
        slot.deadline = now + deadline
        slots[i] = slot
        return i
    }
}

extension Reassembler {
    /// True while a frame older than `frameID` is still in reassembly or still
    /// listed as a whole-frame loss being NACKed for.
    func hasFrameOlderThan(_ frameID: UInt32) -> Bool {
        if slotsHaveOlder(frameID) { return true }
        return missingHasOlder(frameID)
    }
}
