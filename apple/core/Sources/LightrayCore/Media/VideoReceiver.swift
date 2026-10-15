/// A reassembled frame that passed the decodability gate.
public struct DeliveredFrame: Sendable {
    public let frameID: UInt32
    public let header: FrameHeader
    public let bytes: Bytes
    public let payloadOffset: Int
    /// When its last fragment arrived, on the receiver's clock.
    public let completedAt: UInt64
    var memoryReservations: [MemoryReservation] = []

    public var payload: ArraySlice<UInt8> { bytes[payloadOffset...] }
}

public struct VideoReceiverStats: Sendable {
    public init() {}

    public var framesDelivered = 0
    public var keyframesDelivered = 0
    public var framesLost = 0
    public var framesUndecodable = 0
    public var duplicateFragments = 0
    public var redundantFragments = 0
    public var discardedFragments = 0
    public var nackedFragments = 0
    public var refreshRequests = 0
    /// Data fragments rebuilt from Reed–Solomon parity.
    public var fecRepaired = 0
    public var memoryLimitDrops = 0
}

/// The client side of a `MEDIA` stream, `docs/video.md` version 0 text with provisional FEC
/// scheme 1: places fragments as they arrive, rebuilds missing ones from parity, asks for what
/// parity cannot cover, delivers frames in order behind the decodability gate, and asks for a
/// keyframe when the reference chain breaks.
///
/// Late is not lost. A frame is given up only once its deadline has passed while the link is
/// carrying traffic; time the link spends silent (a Wi-Fi radio away on AWDL, say) does not
/// count against it, so a stall costs its own length and no keyframe.
public final class VideoReceiver {
    public let stream: UInt8
    public private(set) var stats = VideoReceiverStats()
    public var maxFrameBytes = 32 << 20
    public let memoryBudget: MemoryBudget
    private let sharedBudget: MemoryBudget?
    /// An estimate; the client is not told the frame rate. Used only for the tail timeout.
    public var frameInterval: UInt64 = 16_667

    private let codec = ReedSolomon()
    private var slots: [UInt32: Slot] = [:]
    private var completed = Set<UInt32>()
    private var completedOrder: [UInt32] = []
    private var nextToDeliver: UInt32 = 1
    private var highestSeen: UInt32 = 0
    private var lastDelivered: UInt32 = 0
    private var lastKeyframeDelivered: UInt32 = 0
    /// Whether the frame before `nextToDeliver` reached the decoder with its references.
    private var chainIntact = false
    private var ready: [DeliveredFrame] = []

    // Recovery.
    private var needsRefresh: RefreshRequest.Reason?
    private var lostFrame: UInt32 = 0
    private var attempt: Attempt?
    private var nextReqID: UInt32 = 0

    static let completedMemory = 256
    static let maxSlots = 128
    static let maxHeld = 64
    static let maxGap: UInt32 = 64
    /// With nothing heard for this long the link counts as silent, and no frame is given up.
    public static let silence: UInt64 = 30_000
    /// How far stalls may push a frame's deadline back, in all.
    public static let stallCredit: UInt64 = 400_000

    private struct Attempt {
        let reqID: UInt32
        let reason: RefreshRequest.Reason
        let started: UInt64
        let lifetime: UInt64
        var lastSent: UInt64
    }

    private final class Slot {
        var reservations: [MemoryReservation] = []
        let discovered: UInt64
        var deadline: UInt64
        var extended: UInt64 = 0
        var count = 0
        var stride = 0
        var fec: MediaFragment.FEC?
        var layout: FECLayout?
        /// Data fragments, placed at `index × stride`; a short last fragment leaves zeros behind
        /// it, which is the padding parity was computed over.
        var buffer = Bytes()
        var received: [Bool] = []
        var receivedCount = 0
        /// Parity fragments, block after block, and how many shards each block holds.
        var parity = Bytes()
        var parityReceived: [Bool] = []
        var blockHave: [Int] = []
        /// By send position (each block's data, then its parity): what arrived, and since when a
        /// gap below the highest position has been open.
        var got: [Bool] = []
        var highest = -1
        var holeSince: [UInt64] = []
        /// When a later frame was first seen: proof that this one's tail was sent.
        var laterSeen: UInt64?
        var lastNack: [UInt64] = []
        var lastLength = 0
        var lastArrival: UInt64 = 0
        var firstArrival: UInt64 = 0
        var wholeFrameNack: UInt64 = 0
        var completedAt: UInt64?

        init(now: UInt64, budget: UInt64) {
            discovered = now
            deadline = now + budget
        }

        var known: Bool { count > 0 }
        var isComplete: Bool { completedAt != nil }
        var positions: Int { got.count }

        func position(of f: MediaFragment) -> Int {
            guard let layout else { return Int(f.index) }
            return f.isParity ? layout.position(ofParity: Int(f.index)) : layout.position(ofData: Int(f.index))
        }
    }

    public init(stream: UInt8, firstFrameID: UInt32 = 1, memoryBudget: MemoryBudget = MemoryBudget(limit: 64 << 20), sharedBudget: MemoryBudget? = nil) {
        self.stream = stream
        self.memoryBudget = memoryBudget
        self.sharedBudget = sharedBudget
        nextToDeliver = firstFrameID
    }

    // MARK: Fragments

    public func receive(_ f: MediaFragment, now: UInt64, budget: UInt64) {
        guard f.count > 0, f.stride > 0, !f.payload.isEmpty, f.payload.count <= Int(f.stride) else {
            stats.discardedFragments += 1
            return
        }
        if f.isParity {
            guard let fec = f.fec, let layout = FECLayout(dataCount: Int(f.count), maxBlockLength: Int(fec.maxBlockLength), parityPerBlock: Int(fec.parityPerBlock)), Int(f.index) < layout.parityCount, f.payload.count == Int(f.stride) else {
                stats.discardedFragments += 1
                return
            }
        } else {
            guard f.index < f.count, f.index == f.count - 1 || f.payload.count == Int(f.stride), f.fec == nil || f.index != f.count - 1 || f.payload.count == Int(f.fec!.lastLength) else {
                stats.discardedFragments += 1
                return
            }
        }
        let id = f.frameID
        guard id != 0, !completed.contains(id) else {
            stats.redundantFragments += 1
            return
        }
        // Older than anything still awaited: delivered or given up on already.
        if serialNewer(nextToDeliver, than: id) {
            stats.redundantFragments += 1
            return
        }
        noteFrame(id, now: now, budget: budget)
        guard let slot = slots[id] else {
            stats.discardedFragments += 1
            return
        }
        let count = Int(f.count)
        let stride = Int(f.stride)
        if !slot.known {
            guard allocate(slot, for: f) else {
                stats.discardedFragments += 1
                return
            }
            slot.firstArrival = now
        } else if slot.count != count || slot.stride != stride || slot.fec != f.fec {
            stats.discardedFragments += 1
            return
        }
        let index = Int(f.index)
        if f.isParity {
            guard let layout = slot.layout, !slot.parityReceived[index] else {
                stats.duplicateFragments += 1
                return
            }
            let block = index / layout.parityPerBlock
            if layout.range(ofBlock: block).allSatisfy({ slot.received[$0] }) {
                stats.redundantFragments += 1
                return
            }
            slot.parity.replaceSubrange(index * stride..<(index + 1) * stride, with: f.payload)
            slot.parityReceived[index] = true
            slot.blockHave[block] += 1
        } else {
            guard !slot.received[index] else {
                stats.duplicateFragments += 1
                return
            }
            slot.buffer.withUnsafeMutableBufferPointer { buffer in
                f.payload.withUnsafeBufferPointer { source in
                    (buffer.baseAddress! + index * stride).update(from: source.baseAddress!, count: source.count)
                }
            }
            slot.received[index] = true
            slot.receivedCount += 1
            if let layout = slot.layout { slot.blockHave[layout.block(ofData: index)] += 1 }
            if index == count - 1 { slot.lastLength = f.payload.count }
        }
        slot.lastArrival = now
        let position = slot.position(of: f)
        slot.got[position] = true
        if position > slot.highest {
            for hole in (slot.highest + 1)..<position where !slot.got[hole] { slot.holeSince[hole] = now }
            slot.highest = position
        }
        if let layout = slot.layout {
            rebuild(slot, block: f.isParity ? index / layout.parityPerBlock : layout.block(ofData: index))
        }
        if slot.receivedCount == count {
            slot.completedAt = now
            let lastLength = slot.fec.map { Int($0.lastLength) } ?? slot.lastLength
            slot.buffer.removeLast(stride - lastLength)
            slot.parity = []
            remember(id)
            deliver(now: now)
        }
    }

    /// Sizes a slot from its first fragment; false if the frame is too large to hold.
    private func allocate(_ slot: Slot, for f: MediaFragment) -> Bool {
        let count = Int(f.count)
        let stride = Int(f.stride)
        var layout: FECLayout?
        if let fec = f.fec {
            guard fec.lastLength > 0, fec.lastLength <= f.stride else { return false }
            layout = FECLayout(
                dataCount: count, maxBlockLength: Int(fec.maxBlockLength), parityPerBlock: Int(fec.parityPerBlock))
            guard layout != nil else { return false }
        }
        let parityCount = layout?.parityCount ?? 0
        guard (count + parityCount) * stride <= maxFrameBytes else { return false }
        // Reserve encoded buffers, recovery/copy workspace, and conservative per-fragment metadata before allocating.
        let charge = 2 * (count + parityCount) * stride + (count + parityCount) * 32 + (layout?.blockCount ?? 0) * 8 + 512
        guard let reservation = memoryBudget.reserve(charge, sharing: sharedBudget) else {
            stats.memoryLimitDrops += 1
            return false
        }
        slot.reservations = [reservation]
        slot.count = count
        slot.stride = stride
        slot.fec = f.fec
        slot.layout = layout
        slot.buffer = Bytes(repeating: 0, count: count * stride)
        slot.received = Array(repeating: false, count: count)
        slot.parity = Bytes(repeating: 0, count: parityCount * stride)
        slot.parityReceived = Array(repeating: false, count: parityCount)
        slot.blockHave = Array(repeating: 0, count: layout?.blockCount ?? 0)
        slot.got = Array(repeating: false, count: count + parityCount)
        slot.holeSince = Array(repeating: 0, count: count + parityCount)
        slot.lastNack = Array(repeating: 0, count: count)
        return true
    }

    /// Once a block holds as many shards as it has data fragments, its missing data is rebuilt.
    private func rebuild(_ slot: Slot, block: Int) {
        guard let layout = slot.layout else { return }
        let range = layout.range(ofBlock: block)
        let k = range.count
        let p = layout.parityPerBlock
        let missing = range.filter { !slot.received[$0] }
        guard !missing.isEmpty, slot.blockHave[block] >= k else { return }
        let rows = (0..<p).filter { slot.parityReceived[block * p + $0] }.prefix(missing.count)
        let stride = slot.stride
        slot.parity.withUnsafeBufferPointer { parity in
            let chosen = rows.map { row in
                (row: row, bytes: UnsafeBufferPointer(rebasing: parity[(block * p + row) * stride..<(block * p + row + 1) * stride]))
            }
            slot.buffer.withUnsafeMutableBufferPointer { buffer in
                codec.recover(
                    UnsafeMutableBufferPointer(rebasing: buffer[range.lowerBound * stride..<range.upperBound * stride]),
                    k: k, p: p, length: stride, missing: missing.map { $0 - range.lowerBound }, parity: chosen)
            }
        }
        for index in missing {
            slot.received[index] = true
            slot.got[layout.position(ofData: index)] = true
        }
        slot.receivedCount += missing.count
        slot.blockHave[block] = k + p
        stats.fecRepaired += missing.count
    }

    /// Opens slots for a newly seen frame and for any frame skipped before it, so that a frame
    /// lost entirely can be asked for. Every frame still open learns that a later one exists.
    private func noteFrame(_ id: UInt32, now: UInt64, budget: UInt64) {
        guard slots[id] == nil else { return }
        let base = highestSeen == 0 ? previous(nextToDeliver) : highestSeen
        if serialNewer(id, than: base) {
            let gap = id &- base
            if gap > Self.maxGap {
                // Too far ahead to repair: give up on everything before it.
                for (key, _) in slots where serialNewer(id, than: key) { slots[key] = nil }
                nextToDeliver = id
                breakChain(lost: previous(id))
            } else {
                var skipped = next(base)
                while skipped != id {
                    if slots.count < Self.maxSlots, slots[skipped] == nil, !completed.contains(skipped) { slots[skipped] = Slot(now: now, budget: budget) }
                    skipped = next(skipped)
                }
            }
            highestSeen = id
            for slot in slots.values where !slot.isComplete && slot.laterSeen == nil { slot.laterSeen = now }
        }
        if slots.count < Self.maxSlots { slots[id] = Slot(now: now, budget: budget) }
    }

    private func remember(_ id: UInt32) {
        completed.insert(id)
        completedOrder.append(id)
        if completedOrder.count > Self.completedMemory { completed.remove(completedOrder.removeFirst()) }
    }

    // MARK: Delivery

    /// Delivers, in `frame_id` order, every frame at the head of the queue that is complete, and
    /// discards the ones whose references are gone.
    private func deliver(now: UInt64) {
        while let slot = slots[nextToDeliver], slot.isComplete {
            let id = nextToDeliver
            slots[id] = nil
            advance()
            guard let (header, offset) = FrameHeader.parse(slot.buffer) else {
                breakChain(lost: id)
                continue
            }
            let deliverable: Bool
            switch header.refKind {
            case .none: deliverable = header.frameType == .idr
            case .previous: deliverable = chainIntact && lastDelivered == previous(id)
            case .ltr, .ltrAny: deliverable = false
            }
            guard deliverable else {
                stats.framesUndecodable += 1
                breakChain(lost: id)
                continue
            }
            chainIntact = true
            lastDelivered = id
            ready.append(DeliveredFrame(
                frameID: id, header: header, bytes: slot.buffer, payloadOffset: offset, completedAt: slot.completedAt!, memoryReservations: slot.reservations))
            stats.framesDelivered += 1
            if header.frameType == .idr {
                stats.keyframesDelivered += 1
                lastKeyframeDelivered = id
            }
        }
    }

    private func advance() { nextToDeliver = next(nextToDeliver) }

    private func breakChain(lost: UInt32) {
        chainIntact = false
        lostFrame = lost
        if needsRefresh == nil { needsRefresh = .loss }
    }

    /// Frames ready for the decoder, in order.
    public func takeFrames() -> [DeliveredFrame] {
        defer { ready.removeAll() }
        return ready
    }

    // MARK: Decoder reports

    /// The decoder produced a picture from this frame. A keyframe that follows the last loss
    /// ends the recovery attempt.
    public func decoded(frameID: UInt32, isKeyframe: Bool) {
        if isKeyframe, lostFrame == 0 || serialNewer(frameID, than: lostFrame) {
            attempt = nil
            needsRefresh = nil
        }
    }

    /// The decoder failed on this frame: predicted frames are refused until a keyframe arrives,
    /// and a keyframe is requested. A failure behind a keyframe already delivered is left to it.
    public func decoderFailed(frameID: UInt32) {
        if lastKeyframeDelivered != 0, serialNewer(lastKeyframeDelivered, than: frameID) { return }
        chainIntact = false
        if lostFrame == 0 || serialNewer(frameID, than: lostFrame) { lostFrame = frameID }
        if needsRefresh != .decoderReset {
            needsRefresh = .decoderReset
            attempt = nil
        }
    }

    // MARK: Timers

    /// The link was silent for `gap` and has just carried a datagram again: every frame still
    /// open gets that time back, up to `stallCredit` in all.
    public func linkResumed(after gap: UInt64) {
        for slot in slots.values where !slot.isComplete {
            let extra = min(gap, Self.stallCredit - slot.extended)
            slot.deadline += extra
            slot.extended += extra
        }
    }

    /// Gives up on late frames, and returns the NACK and REFRESH_REQUEST chunks due now.
    /// `lastHeard` is when the link last carried anything; nil treats it as live.
    public func poll(now: UInt64, srtt: UInt64, budget: UInt64, lastHeard: UInt64? = nil) -> [Chunk] {
        if !isSilent(now: now, lastHeard: lastHeard) { expire(now: now) }
        var chunks: [Chunk] = []
        if let nack = buildNack(now: now, srtt: srtt) { chunks.append(.nack(nack)) }
        if let refresh = refresh(now: now, srtt: srtt, budget: budget) { chunks.append(.refreshRequest(refresh)) }
        return chunks
    }

    private func isSilent(now: UInt64, lastHeard: UInt64?) -> Bool {
        guard let lastHeard else { return false }
        return now > lastHeard + Self.silence
    }

    private func expire(now: UInt64) {
        while true {
            if let slot = slots[nextToDeliver] {
                let held = slots.values.lazy.filter(\.isComplete).count
                guard (!slot.isComplete && now >= slot.deadline) || held > Self.maxHeld else { break }
            } else {
                // Never seen. Gaps get slots when a later frame shows up, so with a later frame
                // seen and no slot, the slot could not be kept: the frame is lost.
                guard highestSeen != 0, highestSeen == nextToDeliver || serialNewer(highestSeen, than: nextToDeliver)
                else { break }
            }
            let lost = nextToDeliver
            slots[lost] = nil
            remember(lost)
            advance()
            stats.framesLost += 1
            breakChain(lost: lost)
            deliver(now: now)
        }
    }

    /// Asks for what parity cannot cover. A fragment counts as lost once something sent after
    /// it has arrived and the reorder window has passed: a later position of its frame, or a
    /// later frame; a tail with neither falls back to a timer. In each block, as many data
    /// fragments are asked for as the block would still lack if everything not yet known lost
    /// arrived, less those already asked for within the retry interval.
    private func buildNack(now: UInt64, srtt: UInt64) -> Nack? {
        let reorder = max(1_000, srtt / 4)
        let retry = max(srtt * 3 / 2, 2_000)
        var entries: [NackEntry] = []
        for id in slots.keys.sorted(by: { serialNewer($1, than: $0) }) {
            if entries.count == 128 { break }
            let slot = slots[id]!
            guard !slot.isComplete, now < slot.deadline else { continue }
            if !slot.known {
                let first = slot.wholeFrameNack == 0 && now >= slot.discovered + reorder
                if first || (slot.wholeFrameNack != 0 && now >= slot.wholeFrameNack + retry) {
                    entries.append(NackEntry(frameID: id, first: 0, count: 0))
                    slot.wholeFrameNack = now
                }
                continue
            }
            let tailKnown = slot.laterSeen.map { now >= $0 + reorder } ?? false
                || (now >= slot.firstArrival + 2 * frameInterval && now >= slot.lastArrival + reorder)
            func knownLost(_ position: Int) -> Bool {
                !slot.got[position] && (position < slot.highest ? now >= slot.holeSince[position] + reorder : tailKnown)
            }
            var wanted: [Int] = []
            let blocks = slot.layout?.blockCount ?? 1
            for b in 0..<blocks {
                let data = slot.layout?.range(ofBlock: b) ?? 0..<slot.count
                let parity = slot.layout.map { b * $0.parityPerBlock..<(b + 1) * $0.parityPerBlock } ?? 0..<0
                var lost = 0
                var outstanding = 0
                var eligible: [Int] = []
                for i in data where !slot.received[i] {
                    guard knownLost(slot.layout?.position(ofData: i) ?? i) else { continue }
                    lost += 1
                    if slot.lastNack[i] != 0, now < slot.lastNack[i] + retry {
                        outstanding += 1
                    } else {
                        eligible.append(i)
                    }
                }
                for j in parity where !slot.parityReceived[j] && knownLost(slot.layout!.position(ofParity: j)) { lost += 1 }
                let need = lost - parity.count - outstanding
                if need > 0 { wanted += eligible.prefix(need) }
            }
            var run: (first: Int, count: Int)?
            for i in wanted {
                if let r = run, r.first + r.count == i {
                    run = (r.first, r.count + 1)
                } else {
                    if let r = run { entries.append(NackEntry(frameID: id, first: UInt16(r.first), count: UInt16(r.count))) }
                    // Leave omitted ranges due for the next poll rather than marking them as requested.
                    if entries.count == 128 { return Nack(stream: stream, entries: entries) }
                    run = (i, 1)
                }
                slot.lastNack[i] = now
                stats.nackedFragments += 1
            }
            if let r = run { entries.append(NackEntry(frameID: id, first: UInt16(r.first), count: UInt16(r.count))) }
        }
        guard !entries.isEmpty else { return nil }
        return Nack(stream: stream, entries: entries)
    }

    private func refresh(now: UInt64, srtt: UInt64, budget: UInt64) -> RefreshRequest? {
        guard let reason = needsRefresh else { return nil }
        if let a = attempt, now >= a.started + a.lifetime { attempt = nil }
        if attempt == nil {
            attempt = Attempt(
                reqID: nextReqID, reason: reason, started: now, lifetime: max(2 * budget, 3 * srtt), lastSent: 0)
            nextReqID &+= 1
        }
        guard var a = attempt, a.lastSent == 0 || now >= a.lastSent + max(srtt, 10_000) else { return nil }
        a.lastSent = now
        attempt = a
        stats.refreshRequests += 1
        return RefreshRequest(
            stream: stream, reason: a.reason, preferred: .idr, lastGoodFrame: lastDelivered, lostFrame: lostFrame,
            reqID: a.reqID)
    }

    /// While the link is silent no deadline can fire, so none is asked to wake anyone.
    public func nextDeadline(now: UInt64, srtt: UInt64, lastHeard: UInt64? = nil) -> UInt64? {
        let silent = isSilent(now: now, lastHeard: lastHeard)
        var deadline: UInt64?
        func consider(_ t: UInt64) { deadline = min(deadline ?? .max, t) }
        for slot in slots.values where !slot.isComplete {
            if !silent { consider(slot.deadline) }
            consider(now + max(1_000, srtt / 4))
        }
        if let a = attempt { consider(min(a.started + a.lifetime, a.lastSent + max(srtt, 10_000))) }
        if needsRefresh != nil, attempt == nil { consider(now) }
        return deadline
    }

    private func next(_ id: UInt32) -> UInt32 { id == .max ? 1 : id + 1 }
    private func previous(_ id: UInt32) -> UInt32 { id <= 1 ? .max : id - 1 }
}
