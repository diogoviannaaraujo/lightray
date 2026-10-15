import CryptoKit
import Foundation

/// `Noise_NNpsk0_25519_AESGCM_SHA256`, the handshake of `docs/handshake.md`.
///
///     -> psk, e
///     <- e, ee
public enum Noise {
    public static let protocolName = "Noise_NNpsk0_25519_AESGCM_SHA256"
    public static let dhLength = 32
    public static let tagLength = 16

    static func hash(_ data: Bytes) -> Bytes { Array(SHA256.hash(data: data)) }

    static func hmac(key: Bytes, _ data: Bytes) -> Bytes {
        Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// Noise's HKDF with two or three outputs.
    static func hkdf(_ chainingKey: Bytes, _ inputKeyMaterial: Bytes, outputs: Int) -> [Bytes] {
        let temp = hmac(key: chainingKey, inputKeyMaterial)
        var result: [Bytes] = []
        var previous = Bytes()
        for counter in 1...outputs {
            previous = hmac(key: temp, previous + [UInt8(counter)])
            result.append(previous)
        }
        return result
    }

    /// The AESGCM nonce: 32 zero bits, then the 64-bit counter, big-endian.
    static func nonce(_ n: UInt64) -> AES.GCM.Nonce {
        var bytes = Bytes(repeating: 0, count: 12)
        for i in 0..<8 { bytes[4 + i] = UInt8(truncatingIfNeeded: n >> (56 - 8 * UInt64(i))) }
        return try! AES.GCM.Nonce(data: bytes)
    }

    /// AES-256-GCM seal; the result is the ciphertext with the tag appended.
    static func encrypt(key: SymmetricKey, nonce n: UInt64, ad: Bytes, plaintext: Bytes) -> Bytes {
        let box = try! AES.GCM.seal(plaintext, using: key, nonce: nonce(n), authenticating: ad)
        var out = Bytes(box.ciphertext)
        out.append(contentsOf: box.tag)
        return out
    }

    static func decrypt(key: SymmetricKey, nonce n: UInt64, ad: Bytes, ciphertext: ArraySlice<UInt8>) -> Bytes? {
        guard ciphertext.count >= tagLength,
            let box = try? AES.GCM.SealedBox(
                nonce: nonce(n), ciphertext: ciphertext.dropLast(tagLength), tag: ciphertext.suffix(tagLength)),
            let plaintext = try? AES.GCM.open(box, using: key, authenticating: ad)
        else { return nil }
        return Bytes(plaintext)
    }

    /// X25519. Nil when the peer's key is a low-order point, which some libraries report as an
    /// error and others as 32 zero bytes; the handshake treats both as a failure to open.
    static func dh(_ privateKey: Curve25519.KeyAgreement.PrivateKey, _ publicKey: Bytes) -> Bytes? {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey),
            let shared = try? privateKey.sharedSecretFromKeyAgreement(with: peer)
        else { return nil }
        let bytes = shared.withUnsafeBytes { Bytes($0) }
        return bytes.allSatisfy({ $0 == 0 }) ? nil : bytes
    }
}

/// Noise's SymmetricState, with its CipherState folded in: during the handshake the nonce is
/// always 0, because the key changes before each EncryptAndHash.
struct SymmetricState {
    private(set) var ck: Bytes
    private(set) var h: Bytes
    private var k: Bytes?
    private var n: UInt64 = 0

    init() {
        let name = Bytes(Noise.protocolName.utf8)
        // 32 bytes exactly: the name becomes h without hashing.
        h = name.count == 32 ? name : Noise.hash(name)
        ck = h
    }

    mutating func mixHash(_ data: Bytes) { h = Noise.hash(h + data) }

    mutating func mixKey(_ ikm: Bytes) {
        let out = Noise.hkdf(ck, ikm, outputs: 2)
        ck = out[0]
        k = out[1]
        n = 0
    }

    mutating func mixKeyAndHash(_ ikm: Bytes) {
        let out = Noise.hkdf(ck, ikm, outputs: 3)
        ck = out[0]
        mixHash(out[1])
        k = out[2]
        n = 0
    }

    mutating func encryptAndHash(_ plaintext: Bytes) -> Bytes {
        guard let k else { mixHash(plaintext); return plaintext }
        let ciphertext = Noise.encrypt(key: SymmetricKey(data: k), nonce: n, ad: h, plaintext: plaintext)
        n += 1
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: ArraySlice<UInt8>) -> Bytes? {
        guard let k else { mixHash(Bytes(ciphertext)); return Bytes(ciphertext) }
        guard let plaintext = Noise.decrypt(key: SymmetricKey(data: k), nonce: n, ad: h, ciphertext: ciphertext)
        else { return nil }
        n += 1
        mixHash(Bytes(ciphertext))
        return plaintext
    }

    /// The initiator-to-responder key, then the responder-to-initiator key.
    func split() -> (Bytes, Bytes) {
        let out = Noise.hkdf(ck, [], outputs: 2)
        return (out[0], out[1])
    }
}

/// One side of an `NNpsk0` handshake. A value type, so that the initiator can open each
/// candidate RESPONSE on a copy and a RESPONSE that fails leaves nothing changed.
struct NNpsk0 {
    private(set) var symmetric = SymmetricState()
    /// The responder opens the INIT before choosing the ephemeral it answers with, so it can be replaced.
    var ephemeral: Curve25519.KeyAgreement.PrivateKey
    private let psk: Bytes

    var ephemeralPublic: Bytes { Bytes(ephemeral.publicKey.rawRepresentation) }
    var handshakeHash: Bytes { symmetric.h }

    init(prologue: Bytes, psk: Bytes, ephemeral: Curve25519.KeyAgreement.PrivateKey) {
        precondition(psk.count == 32)
        self.psk = psk
        self.ephemeral = ephemeral
        symmetric.mixHash(prologue)
    }

    /// `-> psk, e` with the payload, as the initiator writes it: `e.public ‖ ciphertext`.
    mutating func writeMessageA(payload: Bytes) -> Bytes {
        symmetric.mixKeyAndHash(psk)
        mixEphemeral(ephemeralPublic)
        return ephemeralPublic + symmetric.encryptAndHash(payload)
    }

    /// Returns the payload and the initiator's ephemeral key, or nil if the message fails to open.
    mutating func readMessageA(_ message: ArraySlice<UInt8>) -> (payload: Bytes, remote: Bytes)? {
        guard message.count >= Noise.dhLength + Noise.tagLength else { return nil }
        symmetric.mixKeyAndHash(psk)
        let remote = Bytes(message.prefix(Noise.dhLength))
        mixEphemeral(remote)
        guard let payload = symmetric.decryptAndHash(message.dropFirst(Noise.dhLength)) else { return nil }
        return (payload, remote)
    }

    /// `<- e, ee` with the payload. Nil if the DH fails.
    mutating func writeMessageB(payload: Bytes, remote: Bytes) -> Bytes? {
        mixEphemeral(ephemeralPublic)
        guard let shared = Noise.dh(ephemeral, remote) else { return nil }
        symmetric.mixKey(shared)
        return ephemeralPublic + symmetric.encryptAndHash(payload)
    }

    mutating func readMessageB(_ message: ArraySlice<UInt8>) -> Bytes? {
        guard message.count >= Noise.dhLength + Noise.tagLength else { return nil }
        let remote = Bytes(message.prefix(Noise.dhLength))
        mixEphemeral(remote)
        guard let shared = Noise.dh(ephemeral, remote) else { return nil }
        symmetric.mixKey(shared)
        return symmetric.decryptAndHash(message.dropFirst(Noise.dhLength))
    }

    private mutating func mixEphemeral(_ publicKey: Bytes) {
        symmetric.mixHash(publicKey)
        symmetric.mixKey(publicKey)
    }
}
