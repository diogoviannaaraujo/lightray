import CryptoKit
import Foundation

// Spike 2: CryptoKit AES-128-GCM per-packet cost and allocations, nonce = IV ⊕ pn,
// detached tag with the 16-byte header as AAD, plus handshake primitive costs.

struct PacketKeys {
    let key: SymmetricKey
    let iv: (UInt64, UInt32)  // 12 bytes, host order halves

    init(key: SymmetricKey, iv: [UInt8]) {
        self.key = key
        let hi = iv[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let lo = iv[4..<12].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        self.iv = (lo, hi)
    }

    /// IV ⊕ 64-bit packet number (left-padded), built on the stack.
    @inline(__always)
    func nonce(_ pn: UInt64) -> AES.GCM.Nonce {
        var bytes: (UInt32, UInt64) = (iv.1.bigEndian, (iv.0 ^ pn).bigEndian)
        return withUnsafeBytes(of: &bytes) { raw in
            // (UInt32, UInt64) has 4 bytes of padding after the UInt32; pack explicitly.
            var packed = (UInt64(0), UInt32(0))
            return withUnsafeMutableBytes(of: &packed) { out in
                out.baseAddress!.copyMemory(from: raw.baseAddress!, byteCount: 4)
                out.baseAddress!.advanced(by: 4).copyMemory(from: raw.baseAddress!.advanced(by: 8), byteCount: 8)
                return try! AES.GCM.Nonce(data: UnsafeRawBufferPointer(rebasing: out[0..<12]))
            }
        }
    }
}

/// Seals `plaintext` into `out` as ciphertext ‖ tag; returns bytes written.
@inline(never)
func sealPacket(_ k: PacketKeys, pn: UInt64, header: UnsafeRawBufferPointer, plaintext: UnsafeRawBufferPointer,
                out: UnsafeMutableRawBufferPointer) -> Int {
    let box = try! AES.GCM.seal(plaintext, using: k.key, nonce: k.nonce(pn), authenticating: header)
    let n = box.ciphertext.copyBytes(to: out)
    let t = box.tag.copyBytes(to: UnsafeMutableRawBufferPointer(rebasing: out[n...]))
    return n + t
}

/// Opens ciphertext ‖ tag into `out`; returns plaintext length or nil when authentication fails.
@inline(never)
func openPacket(_ k: PacketKeys, pn: UInt64, header: UnsafeRawBufferPointer, sealed: UnsafeRawBufferPointer,
                out: UnsafeMutableRawBufferPointer) -> Int? {
    let ctLen = sealed.count - 16
    guard ctLen >= 0,
          let box = try? AES.GCM.SealedBox(nonce: k.nonce(pn),
                                           ciphertext: UnsafeRawBufferPointer(rebasing: sealed[..<ctLen]),
                                           tag: UnsafeRawBufferPointer(rebasing: sealed[ctLen...])),
          let pt = try? AES.GCM.open(box, using: k.key, authenticating: header)
    else { return nil }
    return pt.copyBytes(to: out)
}

public func cryptoProbe(quick: Bool = false) -> Report {
    var rep = Report("Spike 2 — CryptoKit AES-128-GCM per 1200-byte packet")
    let keys = PacketKeys(key: SymmetricKey(size: .bits128), iv: (0..<12).map { _ in UInt8.random(in: 0...255) })
    let ptLen = 1200 - 16 - 16
    let header = UnsafeMutableRawBufferPointer.allocate(byteCount: 16, alignment: 16)
    header.initializeMemory(as: UInt8.self, repeating: 0x11)
    let pt = UnsafeMutableRawBufferPointer.allocate(byteCount: ptLen, alignment: 16)
    pt.initializeMemory(as: UInt8.self, repeating: 0xAB)
    let sealed = UnsafeMutableRawBufferPointer.allocate(byteCount: 2048, alignment: 16)
    let opened = UnsafeMutableRawBufferPointer.allocate(byteCount: 2048, alignment: 16)
    defer { header.deallocate(); pt.deallocate(); sealed.deallocate(); opened.deallocate() }
    let H = UnsafeRawBufferPointer(header), P = UnsafeRawBufferPointer(pt)

    // Correctness: round trip, tamper, wrong pn, nonce layout.
    let sLen = sealPacket(keys, pn: 42, header: H, plaintext: P, out: sealed)
    let S = UnsafeRawBufferPointer(rebasing: sealed[..<sLen])
    let rt = openPacket(keys, pn: 42, header: H, sealed: S, out: opened) == ptLen && memcmp(opened.baseAddress!, pt.baseAddress!, ptLen) == 0
    header[3] ^= 1
    let tamperHeader = openPacket(keys, pn: 42, header: H, sealed: S, out: opened) == nil
    header[3] ^= 1
    let wrongPN = openPacket(keys, pn: 43, header: H, sealed: S, out: opened) == nil
    sealed[100] ^= 1
    let tamperBody = openPacket(keys, pn: 42, header: H, sealed: S, out: opened) == nil
    sealed[100] ^= 1
    let n1 = keys.nonce(1).withUnsafeBytes { Array($0) }, n2 = keys.nonce(2).withUnsafeBytes { Array($0) }
    rep.add("round trip \(rt); tampered header rejected \(tamperHeader); tampered body rejected \(tamperBody); wrong pn rejected \(wrongPN)")
    rep.add("nonce(1) vs nonce(2) differ only in last byte: \(n1[0..<11] == n2[0..<11] && n1[11] != n2[11]); sealed length \(sLen) = pt + 16")

    let iters = quick ? 20_000 : 200_000
    let nonce = bench(iterations: iters) { i in blackHole(keys.nonce(UInt64(i))) }
    rep.add("nonce construction:                 \(nonce.description)")
    let seal = bench(iterations: iters) { i in blackHole(sealPacket(keys, pn: UInt64(i), header: H, plaintext: P, out: sealed)) }
    rep.add("seal 1168 B + copy to packet:       \(seal.description)")
    let open = bench(iterations: iters) { _ in blackHole(openPacket(keys, pn: 42, header: H, sealed: S, out: opened)) }
    rep.add("open 1168 B + copy out:             \(open.description)")
    let memcpyCost = bench(iterations: iters) { _ in opened.baseAddress!.copyMemory(from: pt.baseAddress!, byteCount: ptLen); blackHole(opened[5]) }
    rep.add("memcpy 1168 B (floor):              \(memcpyCost.description)")
    let chacha = ChaChaPoly.Nonce()
    let cc = bench(iterations: iters) { _ in blackHole(try! ChaChaPoly.seal(P, using: keys.key.withUnsafeBytes { _ in SymmetricKey(size: .bits256) }, nonce: chacha, authenticating: H)) }
    rep.add("(ref) ChaChaPoly seal incl. keygen: \(cc.description)")
    let gbps = { (ns: Double) in 1200.0 * 8 / ns }
    rep.add(String(format: "crypto-only ceiling: seal %.1f Gbps, open %.1f Gbps per core (1 Gbps needs ≤ 9600 ns/pkt total)", gbps(seal.nsPerOp), gbps(open.nsPerOp)))

    // Handshake primitives: NNpsk0-shaped schedule on each side.
    let psk = SymmetricKey(size: .bits256)
    let hs = bench(iterations: quick ? 500 : 5_000) { _ in
        let eC = Curve25519.KeyAgreement.PrivateKey(), eH = Curve25519.KeyAgreement.PrivateKey()
        let dh = try! eC.sharedSecretFromKeyAgreement(with: eH.publicKey)
        var transcript = SHA256()
        transcript.update(data: eC.publicKey.rawRepresentation); transcript.update(data: eH.publicKey.rawRepresentation)
        let th = transcript.finalize()
        let prk = dh.withUnsafeBytes { dhb in
            psk.withUnsafeBytes { pskb in HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: Data(dhb) + Data(pskb)), salt: Data(th)) }
        }
        for label in ["c2s key", "c2s iv", "s2c key", "s2c iv"] {
            blackHole(HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data(label.utf8), outputByteCount: label.hasSuffix("iv") ? 12 : 16))
        }
    }
    rep.add(String(format: "handshake math (2×X25519 keygen + DH + SHA256 transcript + HKDF 4 outputs): %.1f µs", hs.nsPerOp / 1000))
    let secret = SymmetricKey(size: .bits256)
    let token = bench(iterations: iters) { i in
        var sid = UInt32(truncatingIfNeeded: i).bigEndian
        blackHole(withUnsafeBytes(of: &sid) { HMAC<SHA256>.authenticationCode(for: $0, using: secret) })
    }
    rep.add("stateless-reset token HMAC-SHA256(session_id): \(token.description)")
    return rep
}
