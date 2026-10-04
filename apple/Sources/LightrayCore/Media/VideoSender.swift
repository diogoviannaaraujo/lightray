/// A frame as the encoder hands it over.
public struct EncodedFrame: Sendable {
    public var isKeyframe: Bool
    /// The access unit's NAL units, each behind a 4-byte big-endian length, without start codes.
    public var payload: Bytes
    /// VPS, SPS and PPS; required on a keyframe.
    public var codecConfig: CodecConfig?
    /// The capture instant on the sender's monotonic clock, in microseconds.
    public var captureTimeMicros: UInt64
    public var hostTimings: HostFrameTimings?

    public init(isKeyframe: Bool, payload: Bytes, codecConfig: CodecConfig?, captureTimeMicros: UInt64, hostTimings: HostFrameTimings? = nil) {
        self.isKeyframe = isKeyframe
        self.payload = payload
        self.codecConfig = codecConfig
        self.captureTimeMicros = captureTimeMicros
        self.hostTimings = hostTimings
    }
}

public struct VideoSenderStats: Sendable {
    public init() {}

    public var frames = 0
    public var keyframes = 0
    public var fragments = 0
    public var retransmissions = 0
    public var expired = 0
    public var refreshRequests = 0
    /// Reed–Solomon parity fragments sent.
    public var parityFragments = 0
}

/// Token-bucket pacing, `docs/video.md#pacing`. The rate follows the whole backlog: at least
/// 1.25 × the bitrate, and fast enough to drain everything queued within a frame interval of the
/// last frame submitted. Bursts are at most 32 datagrams.
///
/// A rate of `backlog / frame_interval` recomputed as the backlog shrinks would slow down as it
/// drains and leave the tail of a large frame trickling out at the floor rate; aiming at a fixed
/// drain time keeps the whole frame inside the interval.
struct Pacer {
    var bitrate: Int
    var frameInterval: UInt64
    private var tokens: Double = 0
    private var lastRefill: UInt64?
    private var drainBy: UInt64 = 0
    static let burstDatagrams = 32
    static let minimumDrainTime: UInt64 = 2_000

    init(bitrate: Int, frameInterval: UInt64) {
        self.bitrate = bitrate
        self.frameInterval = frameInterval
    }

    mutating func frameSubmitted(now: UInt64) { drainBy = now + frameInterval }

    /// Bytes per second.
    func rate(backlog: Int, now: UInt64) -> Double {
        let remaining = max(drainBy > now ? drainBy - now : 0, Self.minimumDrainTime)
        return max(1.25 * Double(bitrate) / 8, Double(backlog) * 1_000_000 / Double(remaining))
    }

    mutating func refill(now: UInt64, backlog: Int, datagramSize: Int) {
        let burst = Double(Self.burstDatagrams * datagramSize)
        if let last = lastRefill {
            if now > last { tokens = min(burst, tokens + rate(backlog: backlog, now: now) * Double(now - last) / 1_000_000) }
        } else {
            tokens = burst
        }
        lastRefill = now
    }

    mutating func spend(_ bytes: Int) -> Bool {
        guard tokens >= Double(bytes) else { return false }
        tokens -= Double(bytes)
        return true
    }

    /// Microseconds until `bytes` will be affordable.
    func wait(for bytes: Int, backlog: Int, now: UInt64) -> UInt64 {
        let missing = Double(bytes) - tokens
        return missing <= 0 ? 0 : UInt64(missing / rate(backlog: backlog, now: now) * 1_000_000) + 1
    }
}

/// The host side of a `MEDIA` stream: numbers frames, fragments them, adds Reed–Solomon parity
/// when FEC is on, paces them out, keeps them for retransmission, answers NACKs, and turns each
/// new refresh request into one keyframe.
public final class VideoSender {
    public let stream: UInt8
    public private(set) var stats = VideoSenderStats()
    /// Parity as a percentage of each block's data fragments; 0 sends none (scheme `NONE`).
    public var fecPercent = 0
    /// The least parity fragments a block gets, however small.
    public var fecMinParity = 1
    var pacer: Pacer
    private let codec = ReedSolomon()
    private var nextFrameID: UInt32 = 1
    private var frames: [UInt32: StoredFrame] = [:]
    private var order: [UInt32] = []
    private var storedBytes = 0
    private var newQueue: [Item] = []
    private var newHead = 0
    private var retransmitQueue: [Item] = []
    private var queuedRetransmissions = Set<Item>()
    private var refreshSeen: [(reqID: UInt32, time: UInt64)] = []

    static let retention: UInt64 = 500_000
    static let maxStoredBytes = 16 << 20
    /// How far the client's stalls may push a frame's deadline back, in all.
    public static let stallCredit: UInt64 = 400_000

    private struct Item: Hashable {
        let frameID: UInt32
        let index: Int
        var parity = false
    }

    private final class StoredFrame {
        let bytes: Bytes
        let stride: Int
        let count: Int
        let isKeyframe: Bool
        let submitted: UInt64
        var deadline: UInt64
        var extended: UInt64 = 0
        let fec: MediaFragment.FEC?
        /// Every parity fragment, block after block, each `stride` bytes.
        let parity: Bytes
        var lastSent: [UInt64?]

        init(bytes: Bytes, stride: Int, isKeyframe: Bool, submitted: UInt64, deadline: UInt64, fec: MediaFragment.FEC?, parity: Bytes) {
            self.bytes = bytes
            self.stride = stride
            count = max(1, (bytes.count + stride - 1) / stride)
            self.isKeyframe = isKeyframe
            self.submitted = submitted
            self.deadline = deadline
            self.fec = fec
            self.parity = parity
            lastSent = Array(repeating: nil, count: count)
        }

        func payload(_ item: Item) -> ArraySlice<UInt8> {
            if item.parity { return parity[item.index * stride..<(item.index + 1) * stride] }
            return bytes[item.index * stride..<min((item.index + 1) * stride, bytes.count)]
        }

        var overhead: Int { MediaFragment.datagramOverhead(fec: fec != nil) }
    }

    public init(stream: UInt8, bitrate: Int, frameRate: Int, firstFrameID: UInt32 = 1) {
        self.stream = stream
        nextFrameID = firstFrameID
        pacer = Pacer(bitrate: bitrate, frameInterval: UInt64(1_000_000 / max(frameRate, 1)))
    }

    public var bitrate: Int {
        get { pacer.bitrate }
        set { pacer.bitrate = newValue }
    }

    private var backlog: Int {
        var bytes = 0
        for item in retransmitQueue { bytes += size(item) }
        for item in newQueue[newHead...] { bytes += size(item) }
        return bytes
    }

    private func size(_ item: Item) -> Int {
        guard let frame = frames[item.frameID] else { return 0 }
        return frame.payload(item).count + frame.overhead
    }

    /// Queues an encoded frame. The deadline, after which none of it is sent, is `budget` from now.
    public func submit(_ frame: EncodedFrame, now: UInt64, datagramSize: Int, budget: UInt64) {
        let header = FrameHeader(
            frameType: frame.isKeyframe ? .idr : .predicted, refKind: frame.isKeyframe ? .none : .previous,
            captureTimeMicros: UInt32(truncatingIfNeeded: frame.captureTimeMicros),
            codecConfig: frame.isKeyframe ? frame.codecConfig : nil, hostTimings: frame.hostTimings)
        let id = nextFrameID
        nextFrameID = nextFrameID == .max ? 1 : nextFrameID + 1
        let bytes = header.encoded + frame.payload
        let protected = fecPercent > 0
        let stride = MediaFragment.stride(forDatagramSize: datagramSize, fec: protected)
        let count = max(1, (bytes.count + stride - 1) / stride)
        var layout: FECLayout?
        var fec: MediaFragment.FEC?
        var parity = Bytes()
        if protected {
            let l = FECLayout.forFrame(dataCount: count, percent: fecPercent, minParity: fecMinParity)
            layout = l
            fec = MediaFragment.FEC(
                maxBlockLength: UInt8(l.maxBlockLength), parityPerBlock: UInt8(l.parityPerBlock),
                lastLength: UInt16(bytes.count - (count - 1) * stride))
            parity = encodeParity(bytes, layout: l, stride: stride)
        }
        let stored = StoredFrame(
            bytes: bytes, stride: stride, isKeyframe: frame.isKeyframe, submitted: now, deadline: now + budget, fec: fec,
            parity: parity)
        frames[id] = stored
        order.append(id)
        storedBytes += stored.bytes.count + stored.parity.count
        evict(now: now)
        if let layout {
            // Each block's data, then its parity, so parity also shows the block was sent whole.
            for b in 0..<layout.blockCount {
                for index in layout.range(ofBlock: b) { newQueue.append(Item(frameID: id, index: index)) }
                for j in 0..<layout.parityPerBlock {
                    newQueue.append(Item(frameID: id, index: b * layout.parityPerBlock + j, parity: true))
                }
            }
        } else {
            for index in 0..<stored.count { newQueue.append(Item(frameID: id, index: index)) }
        }
        pacer.frameSubmitted(now: now)
        stats.frames += 1
        if frame.isKeyframe { stats.keyframes += 1 }
    }

    /// Every block's parity, the last data fragment zero-padded to the stride.
    private func encodeParity(_ bytes: Bytes, layout: FECLayout, stride: Int) -> Bytes {
        let p = layout.parityPerBlock
        var parity = Bytes(repeating: 0, count: layout.parityCount * stride)
        parity.withUnsafeMutableBufferPointer { out in
            for b in 0..<layout.blockCount {
                let range = layout.range(ofBlock: b)
                let start = range.lowerBound * stride
                let end = range.upperBound * stride
                let target = UnsafeMutableBufferPointer(rebasing: out[b * p * stride..<(b + 1) * p * stride])
                if end <= bytes.count {
                    bytes.withUnsafeBufferPointer { data in
                        codec.encode(
                            UnsafeBufferPointer(rebasing: data[start..<end]), k: range.count, p: p, length: stride, into: target)
                    }
                } else {
                    var padded = Bytes(bytes[start...])
                    padded += Bytes(repeating: 0, count: end - bytes.count)
                    padded.withUnsafeBufferPointer { codec.encode($0, k: range.count, p: p, length: stride, into: target) }
                }
            }
        }
        return parity
    }

    private func evict(now: UInt64) {
        while let oldest = order.first, let frame = frames[oldest],
            now > frame.submitted + Self.retention || storedBytes > Self.maxStoredBytes
        {
            order.removeFirst()
            frames[oldest] = nil
            storedBytes -= frame.bytes.count + frame.parity.count
        }
    }

    /// The client was silent for `gap`: its NACKs were held up with everything else, so every
    /// stored frame's deadline moves back by as much, up to `stallCredit` in all.
    public func extendDeadlines(by gap: UInt64) {
        for frame in frames.values {
            let extra = min(gap, Self.stallCredit - frame.extended)
            frame.deadline += extra
            frame.extended += extra
        }
    }

    /// Queues the requested data fragments for retransmission, unless their frame's deadline has
    /// passed or they were sent within the last half round trip. Parity is never resent.
    public func handle(_ nack: Nack, now: UInt64, srtt: UInt64) {
        for entry in nack.entries {
            guard let frame = frames[entry.frameID], now < frame.deadline else { continue }
            let first = entry.count == 0 ? 0 : Int(entry.first)
            let end = entry.count == 0 ? frame.count : min(frame.count, Int(entry.first) + Int(entry.count))
            guard first < end else { continue }
            for index in first..<end {
                // Never sent yet, so still queued; or sent within the last half round trip.
                guard let sent = frame.lastSent[index], now >= sent + srtt / 2 else { continue }
                let item = Item(frameID: entry.frameID, index: index)
                if queuedRetransmissions.insert(item).inserted { retransmitQueue.append(item) }
            }
        }
    }
    /// True if this request is new and the next frame must be a keyframe. One keyframe per
    /// request identifier, however often the request is repeated.
    public func handle(_ request: RefreshRequest, now: UInt64) -> Bool {
        refreshSeen.removeAll { now > $0.time + 10_000_000 }
        guard !refreshSeen.contains(where: { $0.reqID == request.reqID }) else { return false }
        refreshSeen.append((request.reqID, now))
        if refreshSeen.count > 256 { refreshSeen.removeFirst() }
        stats.refreshRequests += 1
        return true
    }

    /// Paced datagrams due now, retransmissions first. `seal` turns a chunk into a datagram, or
    /// returns nil when the address allowance is spent, which stops sending until later.
    public func drain(now: UInt64, datagramSize: Int, seal: (Bytes) -> Bytes?) -> [Bytes] {
        evict(now: now)
        pacer.refill(now: now, backlog: backlog, datagramSize: datagramSize)
        var out: [Bytes] = []
        while true {
            let fromRetransmit = !retransmitQueue.isEmpty
            guard let item = fromRetransmit ? retransmitQueue.first : (newHead < newQueue.count ? newQueue[newHead] : nil)
            else { break }
            guard let frame = frames[item.frameID], now < frame.deadline else {
                // Late media is dropped rather than queued without bound.
                pop(fromRetransmit)
                stats.expired += 1
                continue
            }
            let payload = frame.payload(item)
            let size = payload.count + frame.overhead
            guard pacer.spend(size) else { break }
            var flags: UInt8 = 0
            if frame.isKeyframe { flags |= MediaFragment.Flag.keyframe }
            if item.index == 0, !item.parity { flags |= MediaFragment.Flag.frameStart }
            if fromRetransmit { flags |= MediaFragment.Flag.retransmission }
            if item.parity { flags |= MediaFragment.Flag.parity }
            var w = ByteWriter(capacity: size)
            MediaFragment(
                stream: stream, flags: flags, frameID: item.frameID, index: UInt16(item.index),
                count: UInt16(frame.count), stride: UInt16(frame.stride), fec: frame.fec, payload: payload
            ).write(to: &w)
            guard let datagram = seal(w.bytes) else { break }
            pop(fromRetransmit)
            if item.parity {
                stats.parityFragments += 1
            } else {
                frame.lastSent[item.index] = now
            }
            out.append(datagram)
            stats.fragments += 1
            if fromRetransmit { stats.retransmissions += 1 }
        }
        if newHead > 1024 {
            newQueue.removeFirst(newHead)
            newHead = 0
        }
        return out
    }

    private func pop(_ fromRetransmit: Bool) {
        if fromRetransmit {
            queuedRetransmissions.remove(retransmitQueue.removeFirst())
        } else {
            newHead += 1
        }
    }

    public var hasBacklog: Bool { !retransmitQueue.isEmpty || newHead < newQueue.count }

    /// When `drain` can next send something.
    public func nextDeadline(now: UInt64) -> UInt64? {
        let item = retransmitQueue.first ?? (newHead < newQueue.count ? newQueue[newHead] : nil)
        guard let item else { return nil }
        return now + pacer.wait(for: size(item), backlog: backlog, now: now)
    }

    /// Drops every queued and stored frame; frame numbering continues.
    public func reset() {
        frames.removeAll()
        order.removeAll()
        storedBytes = 0
        newQueue.removeAll()
        newHead = 0
        retransmitQueue.removeAll()
        queuedRetransmissions.removeAll()
    }
}
