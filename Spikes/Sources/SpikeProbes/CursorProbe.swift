import Darwin
import SpikeCursor

// Spike 1: ~Escapable cursor viability, cost vs raw pointers, allocations, fuzz safety,
// and a pooled slab exposing a borrowed RawSpan (the DecoderHost zero-copy view).

let mds = 1200
let tagSize = 16
let chunkHeaderSize = 3
let fragmentPayload = mds - PacketHeader.size - tagSize - chunkHeaderSize - FragmentHeader.sizeWithFECTLV

/// A pooled buffer that hands out a RawSpan borrowing itself.
public final class Slab {
    public let storage: UnsafeMutableRawBufferPointer
    public var count: Int
    public init(capacity: Int) {
        storage = .allocate(byteCount: capacity, alignment: 16)
        storage.initializeMemory(as: UInt8.self, repeating: 0)
        count = 0
    }
    deinit { storage.deallocate() }

    public var bytes: RawSpan {
        @_lifetime(borrow self) get {
            let span = RawSpan(_unsafeBytes: UnsafeRawBufferPointer(rebasing: storage[..<count]))
            return _overrideLifetime(span, borrowing: self)
        }
    }
}

@inline(never)
func encodeDatagram(into buf: UnsafeMutableRawBufferPointer, seq: UInt32, frameID: UInt32,
                    index: UInt16, count: UInt16, payload: UnsafeRawBufferPointer) throws(WireError) -> Int {
    var w = OutputRawSpan(buffer: buf, initializedCount: 0)
    try PacketHeader(flags: 0, sessionID: 0xA1B2_C3D4, transportSeq: seq, sendTimeUs: seq &* 100).encode(into: &w)
    try w.put(UInt8(0x01))
    try w.put(UInt16(FragmentHeader.sizeWithFECTLV + payload.count))
    try FragmentHeader(stream: 1, flags: 0, frameID: frameID, index: index, count: count).encode(into: &w)
    guard w.freeCapacity >= payload.count + tagSize else { throw .overflow }
    w.withUnsafeMutableBytes { raw, initialized in
        (raw.baseAddress! + initialized).copyMemory(from: payload.baseAddress!, byteCount: payload.count)
        initialized += payload.count
        (raw.baseAddress! + initialized).initializeMemory(as: UInt8.self, repeating: 0, count: tagSize)
        initialized += tagSize
    }
    return w.finalize(for: buf)
}

/// Span-cursor receive path: header, chunk walk, fragment header, payload placement.
@inline(never)
func parseSpan(_ bytes: RawSpan, into dst: UnsafeMutableRawPointer?) throws(WireError) -> UInt64 {
    var r = ByteReader(bytes)
    let h = try PacketHeader.decode(&r)
    guard r.remaining >= tagSize else { throw .truncated }
    var body = ByteReader(try r.take(r.remaining - tagSize))
    var acc = UInt64(h.transportSeq)
    while let chunk = try body.nextChunk() {
        guard chunk.type == 0x01 else { continue }  // must-ignore unknown chunks
        var fr = ByteReader(chunk.body)
        let f = try fr.fragment()
        acc &+= UInt64(f.header.frameID) &+ UInt64(f.payload.byteCount)
        if let dst {
            let offset = Int(f.header.index) &* fragmentPayload
            f.payload.withUnsafeBytes { src in (dst + offset).copyMemory(from: src.baseAddress!, byteCount: src.count) }
        }
    }
    return acc
}

/// Raw-pointer baseline with the same checks.
@inline(never)
func parsePointer(_ p: UnsafeRawBufferPointer, into dst: UnsafeMutableRawPointer?) -> UInt64? {
    @inline(__always) func be32(_ o: Int) -> UInt32 { UInt32(bigEndian: p.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
    @inline(__always) func be16(_ o: Int) -> UInt16 { UInt16(bigEndian: p.loadUnaligned(fromByteOffset: o, as: UInt16.self)) }
    guard p.count >= 16 + tagSize, p[0] & 0x80 == 0 else { return nil }
    let end = p.count - tagSize
    var acc = UInt64(be32(8))
    var o = 16
    while o < end {
        guard end - o >= 3 else { return nil }
        let type = p[o], len = Int(be16(o + 1))
        o += 3
        guard end - o >= len else { return nil }
        if type == 0x01 {
            guard len >= 11 else { return nil }
            let frameID = be32(o + 2), index = be16(o + 6), count = be16(o + 8)
            guard count == 0 || index < count else { return nil }
            let extLen = Int(p[o + 10])
            guard len >= 11 + extLen else { return nil }
            let payloadOff = o + 11 + extLen, payloadLen = len - 11 - extLen
            acc &+= UInt64(frameID) &+ UInt64(payloadLen)
            if let dst { (dst + Int(index) * fragmentPayload).copyMemory(from: p.baseAddress! + payloadOff, byteCount: payloadLen) }
        }
        o += len
    }
    return acc
}

public func cursorProbe(quick: Bool = false) -> Report {
    var rep = Report("Spike 1 — ~Escapable RawSpan cursor + OutputRawSpan writer")
    rep.add("compiles with .enableExperimentalFeature(\"Lifetimes\") on Swift 6.2; @_lifetime spelling (underscored)")
    rep.add("fragment payload at mds=1200: \(fragmentPayload) B (16 hdr + 16 tag + 3 chunk + \(FragmentHeader.sizeWithFECTLV) frag = \(mds - fragmentPayload))")

    let n = 512  // one 500 KB-ish IDR is ~435 fragments
    let payload = UnsafeMutableRawBufferPointer.allocate(byteCount: fragmentPayload, alignment: 16)
    payload.initializeMemory(as: UInt8.self, repeating: 0x5A)
    defer { payload.deallocate() }
    let slabs = (0..<n).map { _ in Slab(capacity: 2048) }
    for (i, s) in slabs.enumerated() {
        s.count = try! encodeDatagram(into: s.storage, seq: UInt32(i), frameID: 7, index: UInt16(i), count: UInt16(n), payload: UnsafeRawBufferPointer(payload))
    }
    let frame = UnsafeMutableRawPointer.allocate(byteCount: n * fragmentPayload, alignment: 64)
    defer { frame.deallocate() }

    // Round trip sanity
    var ok = true
    for s in slabs {
        let a = try? parseSpan(s.bytes, into: nil)
        let b = parsePointer(UnsafeRawBufferPointer(rebasing: s.storage[..<s.count]), into: nil)
        ok = ok && a != nil && a == b
    }
    rep.add("round trip span == pointer parse: \(ok)")

    let iters = quick ? 50_000 : 400_000
    let enc = bench(iterations: iters) { i in
        let s = slabs[i & (n - 1)]
        blackHole(try! encodeDatagram(into: s.storage, seq: UInt32(i), frameID: 7, index: UInt16(i & (n - 1)), count: UInt16(n), payload: UnsafeRawBufferPointer(payload)))
    }
    rep.add("encode hdr+chunk+frag+payload copy (OutputRawSpan):  \(enc.description)")
    let spanParse = bench(iterations: iters) { i in let s = slabs[i & (n - 1)]; blackHole(try! parseSpan(s.bytes, into: nil)) }
    rep.add("parse (span cursor, cross-module @inlinable):       \(spanParse.description)")
    let ptrParse = bench(iterations: iters) { i in
        let s = slabs[i & (n - 1)]
        blackHole(parsePointer(UnsafeRawBufferPointer(rebasing: s.storage[..<s.count]), into: nil))
    }
    rep.add("parse (raw pointer baseline):                        \(ptrParse.description)")
    let spanPlace = bench(iterations: iters) { i in let s = slabs[i & (n - 1)]; blackHole(try! parseSpan(s.bytes, into: frame)) }
    rep.add("parse + place payload at index×stride (span):        \(spanPlace.description)")
    let ptrPlace = bench(iterations: iters) { i in
        let s = slabs[i & (n - 1)]
        blackHole(parsePointer(UnsafeRawBufferPointer(rebasing: s.storage[..<s.count]), into: frame))
    }
    rep.add("parse + place payload at index×stride (pointer):     \(ptrPlace.description)")

    // Fuzz: truncations + random byte flips must throw, never trap or overread.
    var rng = SystemRandomNumberGenerator()
    let fuzzIters = quick ? 100_000 : 2_000_000
    var thrown = 0, parsed = 0
    let scratch = Slab(capacity: 2048)
    for i in 0..<fuzzIters {
        let src = slabs[i & (n - 1)]
        scratch.storage.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.storage[..<src.count]))
        scratch.count = Int.random(in: 0...src.count, using: &rng)
        for _ in 0..<Int.random(in: 0...4, using: &rng) where scratch.count > 0 {
            scratch.storage[Int.random(in: 0..<scratch.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
        }
        do { _ = try parseSpan(scratch.bytes, into: nil); parsed += 1 } catch { thrown += 1 }
    }
    rep.add("fuzz \(fuzzIters) mutated/truncated datagrams: no trap; \(thrown) rejected, \(parsed) accepted")
    return rep
}
