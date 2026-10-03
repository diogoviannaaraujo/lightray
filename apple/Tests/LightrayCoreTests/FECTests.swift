import Testing

@testable import LightrayCore

@Test func galoisFieldTables() {
    // α generates every non-zero element once.
    #expect(Set(GF256.exp[0..<255]).count == 255 && !GF256.exp[0..<255].contains(0))
    for a in 1...255 {
        let a = UInt8(a)
        #expect(GF256.multiply(a, GF256.inverse(a)) == 1)
        for b in [UInt8(0), 1, 2, 0x53, 0xca, 0xff] { #expect(GF256.products[Int(a) << 8 | Int(b)] == GF256.multiply(a, b)) }
    }
    // x⁸ = x⁴ + x³ + x² + 1 under RFC 5510's polynomial.
    #expect(GF256.multiply(0x80, 0x02) == 0x1d)
}

/// The coefficients come from Lagrange interpolation; RFC 5510 §8.2 defines the generator as
/// `V_{k,k}⁻¹ · V_{k,n}`. Built that way independently, the parity columns must agree.
@Test func coefficientsMatchTheRFC5510Generator() {
    let codec = ReedSolomon()
    for (k, p) in [(1, 1), (3, 2), (7, 4), (20, 5)] {
        let n = k + p
        var vkk = [UInt8](repeating: 0, count: k * k)
        for i in 0..<k { for j in 0..<k { vkk[i * k + j] = GF256.power(i * j) } }
        let inverse = ReedSolomon.invert(vkk, size: k)
        let rows = codec.coefficients(k: k, p: p)
        for column in k..<n {
            for i in 0..<k {
                // GM[i][column] = Σ_m V⁻¹[i][m] · α^(m·column)
                var sum: UInt8 = 0
                for m in 0..<k { sum ^= GF256.multiply(inverse[i * k + m], GF256.power(m * column)) }
                #expect(rows[(column - k) * k + i] == sum)
            }
        }
    }
}

/// Encodes k random shards, erases up to p of the k + p (data and parity alike), and rebuilds.
private func roundTrip(k: Int, p: Int, length: Int, erase: [Int], rng: inout SplitMix) -> Bool {
    let codec = ReedSolomon()
    let data = (0..<k * length).map { _ in UInt8.random(in: 0...255, using: &rng) }
    var parity = Bytes(repeating: 0, count: p * length)
    data.withUnsafeBufferPointer { d in
        parity.withUnsafeMutableBufferPointer { codec.encode(d, k: k, p: p, length: length, into: $0) }
    }
    let missing = erase.filter { $0 < k }
    guard !missing.isEmpty else { return true }
    let rows = (0..<p).filter { !erase.contains(k + $0) }.prefix(missing.count)
    guard rows.count == missing.count else { return false }
    var damaged = data
    for i in missing { for b in 0..<length { damaged[i * length + b] = 0xee } }
    parity.withUnsafeBufferPointer { par in
        let chosen = rows.map { (row: $0, bytes: UnsafeBufferPointer(rebasing: par[$0 * length..<($0 + 1) * length])) }
        damaged.withUnsafeMutableBufferPointer {
            codec.recover($0, k: k, p: p, length: length, missing: missing, parity: chosen)
        }
    }
    return damaged == data
}

@Test func rebuildsFromAnyKOfTheShards() {
    var rng = SplitMix(state: 5)
    // Every pattern of up to p erasures, for a small code.
    let (k, p) = (5, 3)
    for mask in 0..<(1 << (k + p)) where mask.nonzeroBitCount <= p {
        let erase = (0..<(k + p)).filter { mask & (1 << $0) != 0 }
        #expect(roundTrip(k: k, p: p, length: 16, erase: erase, rng: &rng), "erased \(erase)")
    }
    // Random patterns across the sizes a sender uses, the largest block included.
    for (k, p) in [(1, 1), (2, 1), (10, 1), (37, 4), (175, 18), (231, 24), (212, 43)] {
        for _ in 0..<4 {
            let erase = Array((0..<(k + p)).shuffled(using: &rng).prefix(Int.random(in: 1...p, using: &rng)))
            #expect(roundTrip(k: k, p: p, length: 64, erase: erase, rng: &rng), "k \(k) p \(p) erased \(erase)")
        }
    }
}

@Test func blocksFollowRFC5052AndSunshineSizes() throws {
    // A 4K keyframe of ~350 fragments at 10 %: two blocks of 175, 18 parity each.
    let keyframe = FECLayout.forFrame(dataCount: 350, percent: 10, minParity: 1)
    #expect(keyframe.maxBlockLength == 231 && keyframe.blockCount == 2 && keyframe.parityPerBlock == 18)
    #expect(keyframe.range(ofBlock: 0) == 0..<175 && keyframe.range(ofBlock: 1) == 175..<350)
    // Sunshine's defaults: 20 %, at least 2; blocks of at most 212.
    let sunshine = FECLayout.forFrame(dataCount: 500, percent: 20, minParity: 2)
    #expect(sunshine.maxBlockLength == 212 && sunshine.blockCount == 3 && sunshine.parityPerBlock == 34)
    // A one-fragment frame still gets its parity.
    let small = FECLayout.forFrame(dataCount: 1, percent: 10, minParity: 1)
    #expect(small.blockCount == 1 && small.parityPerBlock == 1)
    // Uneven splits put the longer blocks first, and send positions map back to fragments.
    for (n, kMax, p) in [(10, 3, 2), (350, 231, 18), (1, 1, 1), (700, 212, 43)] {
        let layout = try #require(FECLayout(dataCount: n, maxBlockLength: kMax, parityPerBlock: p))
        let lengths = (0..<layout.blockCount).map { layout.range(ofBlock: $0).count }
        #expect(lengths.reduce(0, +) == n && lengths == lengths.sorted(by: >) && lengths.first! - lengths.last! <= 1)
        var seen = Set<Int>()
        for i in 0..<n {
            let position = layout.position(ofData: i)
            #expect(layout.fragment(at: position) == (false, i) && layout.range(ofBlock: layout.block(ofData: i)).contains(i))
            seen.insert(position)
        }
        for j in 0..<layout.parityCount {
            let position = layout.position(ofParity: j)
            #expect(layout.fragment(at: position) == (true, j))
            seen.insert(position)
        }
        #expect(seen == Set(0..<layout.positionCount))
    }
    // Too many shards for GF(2⁸), or no parity, describe no code.
    #expect(FECLayout(dataCount: 250, maxBlockLength: 250, parityPerBlock: 10) == nil)
    #expect(FECLayout(dataCount: 10, maxBlockLength: 10, parityPerBlock: 0) == nil)
}

/// How long parity takes for a 4K keyframe at 10 %: about 2 ms optimised on an M-series Mac, so
/// table lookups in Swift are enough. Debug builds are two orders slower and are not held to it.
@Test func keyframeParityCost() {
    let stride = MediaFragment.stride(forDatagramSize: 1200, fec: true)
    let frame = EncodedFrame(isKeyframe: true, payload: Bytes(repeating: 0x5a, count: 400_000), codecConfig: CodecConfig(vps: [1], sps: [2], pps: [3]), captureTimeMicros: 0)
    let sender = VideoSender(stream: 1, bitrate: 20_000_000, frameRate: 60)
    sender.fecPercent = 10
    let clock = ContinuousClock()
    let elapsed = clock.measure {
        sender.submit(frame, now: 0, datagramSize: 1200, budget: 100_000)
    }
    let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
    print("parity for a 400 KB keyframe (\((400_000 + stride - 1) / stride) fragments): \(ms) ms")
    #if !DEBUG
        #expect(ms < 10)
    #endif
}
