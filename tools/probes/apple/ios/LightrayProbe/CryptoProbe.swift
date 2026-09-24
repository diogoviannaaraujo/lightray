// Per-packet AEAD cost on this device for a full 1200-byte datagram (1168-byte body, 16-byte
// header as additional data): AES-256-GCM is what Noise's AESGCM uses; AES-128-GCM and
// ChaCha20-Poly1305 are measured for comparison.
import CryptoKit
import Foundation

enum CryptoProbe {
    static func run() {
        let body = Data(repeating: 0xA5, count: 1168)
        let aad = Data(repeating: 0x01, count: 16)
        let iterations = 20_000
        func nonceBytes(_ i: Int) -> Data {
            var n = Data(repeating: 0, count: 4)
            var be = UInt64(i).bigEndian
            n.append(Data(bytes: &be, count: 8))
            return n
        }
        for (name, key) in [("AES-256-GCM", SymmetricKey(size: .bits256)), ("AES-128-GCM", SymmetricKey(size: .bits128))] {
            var boxes: [AES.GCM.SealedBox] = []
            boxes.reserveCapacity(iterations)
            let t0 = monoNs()
            for i in 0..<iterations {
                boxes.append(try! AES.GCM.seal(body, using: key, nonce: try! AES.GCM.Nonce(data: nonceBytes(i)), authenticating: aad))
            }
            let t1 = monoNs()
            for b in boxes { _ = try! AES.GCM.open(b, using: key, authenticating: aad) }
            let t2 = monoNs()
            report(name, seal: t1 - t0, open: t2 - t1, n: iterations)
        }
        let key = SymmetricKey(size: .bits256)
        var boxes: [ChaChaPoly.SealedBox] = []
        let t0 = monoNs()
        for i in 0..<iterations {
            boxes.append(try! ChaChaPoly.seal(body, using: key, nonce: try! ChaChaPoly.Nonce(data: nonceBytes(i)), authenticating: aad))
        }
        let t1 = monoNs()
        for b in boxes { _ = try! ChaChaPoly.open(b, using: key, authenticating: aad) }
        let t2 = monoNs()
        report("ChaCha20-Poly1305", seal: t1 - t0, open: t2 - t1, n: iterations)
    }

    private static func report(_ name: String, seal: UInt64, open: UInt64, n: Int) {
        let s = Double(seal) / Double(n), o = Double(open) / Double(n)
        // Gb/s of 1200-byte datagrams one core could seal if it did nothing else.
        Report.line(String(format: "CRYPTO %@ seal_ns=%.0f open_ns=%.0f seal_only_ceiling=%.1fGbps", name, s, o, 1200 * 8 / s))
    }
}
