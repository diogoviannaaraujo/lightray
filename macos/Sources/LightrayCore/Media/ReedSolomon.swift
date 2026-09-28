/// GF(2⁸) as RFC 5510 §8.1 represents it: polynomials over GF(2) modulo 1 + x² + x³ + x⁴ + x⁸,
/// with α = x a primitive element.
enum GF256 {
    static let polynomial = 0x11d

    /// αⁱ for i in 0..<510, twice over so that a sum of two logarithms needs no reduction.
    static let exp: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 510)
        var x = 1
        for i in 0..<255 {
            table[i] = UInt8(x)
            table[i + 255] = UInt8(x)
            x <<= 1
            if x & 0x100 != 0 { x ^= polynomial }
        }
        return table
    }()

    /// log_α of every non-zero element; entry 0 is unused.
    static let log: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        for i in 0..<255 { table[Int(exp[i])] = UInt8(i) }
        return table
    }()

    /// Row `a` holds a × b for every b: one lookup per byte when a whole shard is scaled by `a`.
    static let products: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256 * 256)
        for a in 1..<256 {
            for b in 1..<256 { table[a << 8 | b] = exp[Int(log[a]) + Int(log[b])] }
        }
        return table
    }()

    static func multiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        a == 0 || b == 0 ? 0 : exp[Int(log[Int(a)]) + Int(log[Int(b)])]
    }

    static func inverse(_ a: UInt8) -> UInt8 {
        precondition(a != 0, "0 has no inverse")
        return exp[255 - Int(log[Int(a)])]
    }

    static func divide(_ a: UInt8, _ b: UInt8) -> UInt8 { multiply(a, inverse(b)) }

    static func power(_ i: Int) -> UInt8 { exp[i % 255] }
}

/// How a protected frame's data fragments fall into blocks, and the order its fragments are sent
/// in. Blocks follow RFC 5052 §9.1: `ceil(N / maxBlockLength)` of them, the first ones one
/// fragment longer when N does not divide evenly. Every block gets `parityPerBlock` parity
/// fragments, sent right after its data.
struct FECLayout: Equatable, Sendable {
    let dataCount: Int
    let maxBlockLength: Int
    let parityPerBlock: Int
    let blockCount: Int
    private let longLength: Int
    private let shortLength: Int
    private let longBlocks: Int

    /// Nil when the parameters describe no valid code: every block needs data and parity, and
    /// no more than 255 shards in all.
    init?(dataCount: Int, maxBlockLength: Int, parityPerBlock: Int) {
        guard dataCount > 0, maxBlockLength > 0, parityPerBlock > 0 else { return nil }
        self.dataCount = dataCount
        self.maxBlockLength = maxBlockLength
        self.parityPerBlock = parityPerBlock
        blockCount = (dataCount + maxBlockLength - 1) / maxBlockLength
        longLength = (dataCount + blockCount - 1) / blockCount
        shortLength = dataCount / blockCount
        longBlocks = dataCount - shortLength * blockCount
        guard longLength + parityPerBlock <= 255 else { return nil }
    }

    /// The layout a sender uses: blocks as long as they can be with `percent` parity and the
    /// total within 255, as Sunshine sizes them; one parity count, from the longest block.
    static func forFrame(dataCount: Int, percent: Int, minParity: Int) -> FECLayout {
        let minParity = max(1, min(minParity, 254))
        let maxBlock = max(1, min(255 - minParity, 25_500 / (100 + max(0, percent))))
        let blocks = (dataCount + maxBlock - 1) / maxBlock
        let longest = (dataCount + blocks - 1) / blocks
        let parity = min(max(minParity, (longest * percent + 99) / 100), 255 - longest)
        return FECLayout(dataCount: dataCount, maxBlockLength: maxBlock, parityPerBlock: parity)!
    }

    var parityCount: Int { blockCount * parityPerBlock }
    var positionCount: Int { dataCount + parityCount }

    func range(ofBlock b: Int) -> Range<Int> {
        let start = b < longBlocks ? b * longLength : longBlocks * longLength + (b - longBlocks) * shortLength
        return start..<start + (b < longBlocks ? longLength : shortLength)
    }

    func block(ofData index: Int) -> Int {
        let long = longBlocks * longLength
        return index < long ? index / longLength : longBlocks + (index - long) / shortLength
    }

    /// Where a fragment falls in the order the sender sends them: each block's data, then its parity.
    func position(ofData index: Int) -> Int { index + block(ofData: index) * parityPerBlock }

    func position(ofParity index: Int) -> Int {
        let b = index / parityPerBlock
        return range(ofBlock: b).upperBound + index
    }

    /// The fragment at a send position: a data index, or a parity index.
    func fragment(at position: Int) -> (parity: Bool, index: Int) {
        let longSpan = longLength + parityPerBlock
        let shortSpan = shortLength + parityPerBlock
        let b = position < longBlocks * longSpan
            ? position / longSpan : longBlocks + (position - longBlocks * longSpan) / shortSpan
        let blockStart = b < longBlocks ? b * longSpan : longBlocks * longSpan + (b - longBlocks) * shortSpan
        let offset = position - blockStart
        let data = range(ofBlock: b)
        return offset < data.count ? (false, data.lowerBound + offset) : (true, b * parityPerBlock + offset - data.count)
    }
}

/// The systematic Reed–Solomon erasure code of RFC 5510 §8 over GF(2⁸): generator
/// `GM = V_{k,k}⁻¹ · V_{k,n}` with `v_ij = α^(i·j)`, shortened to the first `k + p` columns. Shards
/// are coded byte by byte (§8.4). Encoding element j is the value at αʲ of the polynomial of
/// degree below k that takes the data values at α⁰…α^(k−1), so parity row j's coefficients are
/// the Lagrange basis polynomials evaluated at α^(k+j).
///
/// Not thread-safe: each sender and receiver keeps its own, for the coefficients it caches.
final class ReedSolomon {
    private var cache: [Int: [UInt8]] = [:]

    /// p rows of k coefficients: parity j = Σᵢ coefficients[j·k + i] · dataᵢ.
    func coefficients(k: Int, p: Int) -> [UInt8] {
        precondition(k > 0 && p > 0 && k + p <= 255)
        let key = k << 8 | p
        if let cached = cache[key] { return cached }
        let nodes = (0..<k).map { GF256.power($0) }
        // Π_{l≠i} (xᵢ − x_l), once per k.
        let denominators = nodes.indices.map { i in
            nodes.indices.reduce(UInt8(1)) { $1 == i ? $0 : GF256.multiply($0, nodes[i] ^ nodes[$1]) }
        }
        var rows = [UInt8](repeating: 0, count: p * k)
        for j in 0..<p {
            let y = GF256.power(k + j)
            let numerator = nodes.reduce(UInt8(1)) { GF256.multiply($0, y ^ $1) }
            for i in 0..<k {
                rows[j * k + i] = GF256.divide(numerator, GF256.multiply(y ^ nodes[i], denominators[i]))
            }
        }
        if cache.count > 512 { cache.removeAll() }
        cache[key] = rows
        return rows
    }

    /// Writes p parity shards for k data shards of `length` bytes each, laid end to end.
    func encode(
        _ data: UnsafeBufferPointer<UInt8>, k: Int, p: Int, length: Int, into parity: UnsafeMutableBufferPointer<UInt8>
    ) {
        precondition(data.count >= k * length && parity.count >= p * length)
        let rows = coefficients(k: k, p: p)
        parity.baseAddress!.update(repeating: 0, count: p * length)
        for i in 0..<k {
            let shard = data.baseAddress! + i * length
            for j in 0..<p {
                accumulate(shard, times: rows[j * k + i], into: parity.baseAddress! + j * length, length: length)
            }
        }
    }

    /// Rebuilds the missing data shards of a block in place. `shards` holds the block's k data
    /// shards end to end, the missing ones in any state; `parity` gives, for as many parity
    /// shards as there are missing data shards, the parity row and its bytes.
    func recover(
        _ shards: UnsafeMutableBufferPointer<UInt8>, k: Int, p: Int, length: Int, missing: [Int],
        parity: [(row: Int, bytes: UnsafeBufferPointer<UInt8>)]
    ) {
        let e = missing.count
        precondition(e > 0 && parity.count == e && shards.count >= k * length)
        let rows = coefficients(k: k, p: p)
        let base = shards.baseAddress!
        let lost = Set(missing)
        // What each chosen parity row still owes once the known data is taken out of it.
        var syndromes = [UInt8](repeating: 0, count: e * length)
        syndromes.withUnsafeMutableBufferPointer { syn in
            for (a, (row, bytes)) in parity.enumerated() {
                let target = syn.baseAddress! + a * length
                target.update(from: bytes.baseAddress!, count: length)
                for i in 0..<k where !lost.contains(i) {
                    accumulate(base + i * length, times: rows[row * k + i], into: target, length: length)
                }
            }
        }
        // Those rows restricted to the missing columns form an invertible e × e system (any
        // square submatrix of an MDS code's redundancy part is), solved for the missing shards.
        var matrix = [UInt8](repeating: 0, count: e * e)
        for (a, entry) in parity.enumerated() {
            for (b, column) in missing.enumerated() { matrix[a * e + b] = rows[entry.row * k + column] }
        }
        let inverse = Self.invert(matrix, size: e)
        syndromes.withUnsafeBufferPointer { syn in
            for (b, column) in missing.enumerated() {
                let target = base + column * length
                target.update(repeating: 0, count: length)
                for a in 0..<e {
                    accumulate(syn.baseAddress! + a * length, times: inverse[b * e + a], into: target, length: length)
                }
            }
        }
    }

    /// target ⊕= factor × source, byte by byte.
    private func accumulate(_ source: UnsafePointer<UInt8>, times factor: UInt8, into target: UnsafeMutablePointer<UInt8>, length: Int) {
        switch factor {
        case 0:
            return
        case 1:
            for b in 0..<length { target[b] ^= source[b] }
        default:
            GF256.products.withUnsafeBufferPointer { table in
                let row = table.baseAddress! + Int(factor) << 8
                for b in 0..<length { target[b] ^= row[Int(source[b])] }
            }
        }
    }

    /// Gauss–Jordan elimination; the matrix must be invertible.
    static func invert(_ matrix: [UInt8], size n: Int) -> [UInt8] {
        var m = matrix
        var inverse = [UInt8](repeating: 0, count: n * n)
        for i in 0..<n { inverse[i * n + i] = 1 }
        for column in 0..<n {
            guard let pivot = (column..<n).first(where: { m[$0 * n + column] != 0 }) else {
                preconditionFailure("singular matrix")
            }
            if pivot != column {
                for c in 0..<n {
                    m.swapAt(pivot * n + c, column * n + c)
                    inverse.swapAt(pivot * n + c, column * n + c)
                }
            }
            let scale = GF256.inverse(m[column * n + column])
            for c in 0..<n {
                m[column * n + c] = GF256.multiply(m[column * n + c], scale)
                inverse[column * n + c] = GF256.multiply(inverse[column * n + c], scale)
            }
            for r in 0..<n where r != column {
                let factor = m[r * n + column]
                guard factor != 0 else { continue }
                for c in 0..<n {
                    m[r * n + c] ^= GF256.multiply(factor, m[column * n + c])
                    inverse[r * n + c] ^= GF256.multiply(factor, inverse[column * n + c])
                }
            }
        }
        return inverse
    }
}
