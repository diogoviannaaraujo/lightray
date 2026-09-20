import LightrayCore

/// One submitted frame, held until it leaves the retransmit window.
///
/// The frame header is logically prepended to the payload: fragment `i` covers
/// bytes `[i·stride, (i+1)·stride)` of `header ‖ payload`, so fragmentation never
/// looks at what it is carrying and the payload is never copied.
final class SendFrame {
    let stream: UInt8
    let frameID: UInt32
    let storage: any ByteStorage
    let headerBuffer: UnsafeMutableRawBufferPointer
    let headerLength: Int
    let stride: Int
    let fragmentCount: Int
    let totalBytes: Int
    let flags: FragmentFlags
    let submittedAt: Instant
    let deadline: Instant
    let ltrMarked: Bool
    /// How far the pacer has got through this frame.
    var nextIndex: Int = 0
    private let pool: BufferPool

    init(stream: UInt8, frameID: UInt32, storage: any ByteStorage,
         headerBuffer: UnsafeMutableRawBufferPointer, headerLength: Int,
         stride: Int, flags: FragmentFlags, submittedAt: Instant, deadline: Instant, ltrMarked: Bool,
         pool: BufferPool) {
        self.stream = stream
        self.frameID = frameID
        self.storage = storage
        self.headerBuffer = headerBuffer
        self.headerLength = headerLength
        self.stride = stride
        self.flags = flags
        self.submittedAt = submittedAt
        self.deadline = deadline
        self.ltrMarked = ltrMarked
        self.pool = pool
        self.totalBytes = headerLength + storage.bytes.count
        self.fragmentCount = max(1, (totalBytes + stride - 1) / stride)
    }

    deinit { pool.giveBackLarge(headerBuffer) }

    var isComplete: Bool { nextIndex >= fragmentCount }

    /// Byte range of fragment `index` within `header ‖ payload`.
    func range(of index: Int) -> Range<Int> {
        let lo = index * stride
        return lo..<min(lo + stride, totalBytes)
    }

    func payloadLength(of index: Int) -> Int { range(of: index).count }

    /// Copies a fragment's bytes into a datagram, crossing the header/payload seam.
    func copyFragment(_ index: Int, into w: inout ByteWriter) throws(WireError) {
        let r = range(of: index)
        if r.lowerBound < headerLength {
            let end = min(r.upperBound, headerLength)
            try w.put(bytes: UnsafeRawBufferPointer(rebasing: headerBuffer[r.lowerBound..<end]))
        }
        if r.upperBound > headerLength {
            let lo = max(r.lowerBound, headerLength) - headerLength
            let hi = r.upperBound - headerLength
            let payload = storage.bytes
            guard hi <= payload.count else { throw .malformed }
            try w.put(bytes: UnsafeRawBufferPointer(rebasing: payload[lo..<hi]))
        }
    }

    func fragmentHeader(_ index: Int, retransmission: Bool) -> FragmentHeader {
        var f = flags
        if retransmission { f.insert(.retransmission) }
        if index == 0 { f.insert(.frameStart) }
        return FragmentHeader(stream: stream, flags: f, frameID: frameID,
                              index: UInt16(index), count: UInt16(fragmentCount),
                              stride: UInt16(stride))
    }
}
