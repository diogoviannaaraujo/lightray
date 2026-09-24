import CryptoKit
import Foundation

/// The parts of the Noise Protocol Framework (revision 34) that
/// `Noise_NNpsk0_25519_AESGCM_SHA256` uses, and nothing else.
public enum Noise {
    public static let protocolName = "Noise_NNpsk0_25519_AESGCM_SHA256"
    public static let hashLength = 32
    public static let dhLength = 32
    public static let tagLength = 16

    public static func hash(_ data: Bytes) -> Bytes { Array(SHA256.hash(data: data)) }

    public static func hmac(key: Bytes, _ data: Bytes) -> Bytes {
        Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// Noise's HKDF: RFC 5869 with the chaining key as the salt and an empty info.
    public static func hkdf(_ chainingKey: Bytes, _ inputKeyMaterial: Bytes, outputs: Int) -> [Bytes] {
        precondition(outputs == 2 || outputs == 3)
        let tempKey = hmac(key: chainingKey, inputKeyMaterial)
        var result: [Bytes] = []
        var previous = Bytes()
        for counter in 1...outputs {
            previous = hmac(key: tempKey, previous + [UInt8(counter)])
            result.append(previous)
        }
        return result
    }

    /// The AESGCM nonce: 32 bits of zeros, then the 64-bit counter, big-endian.
    public static func nonceBytes(_ n: UInt64) -> Bytes { [0, 0, 0, 0] + be64(n) }

    /// AES-256-GCM. The result is the ciphertext with the 16-byte tag appended.
    public static func encrypt(key: Bytes, nonce n: UInt64, ad: Bytes, plaintext: Bytes) -> Bytes {
        precondition(key.count == 32)
        let box = try! AES.GCM.seal(
            plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonceBytes(n)),
            authenticating: ad)
        return Array(box.ciphertext) + Array(box.tag)
    }

    public static func decrypt(key: Bytes, nonce n: UInt64, ad: Bytes, ciphertext: Bytes) -> Bytes? {
        guard key.count == 32, ciphertext.count >= tagLength,
            let box = try? AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceBytes(n)),
                ciphertext: Array(ciphertext.dropLast(tagLength)),
                tag: Array(ciphertext.suffix(tagLength))),
            let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: ad)
        else { return nil }
        return Array(plaintext)
    }

    public static func publicKey(_ privateKey: Bytes) -> Bytes {
        Array(try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey).publicKey.rawRepresentation)
    }

    /// X25519.
    public static func dh(_ privateKey: Bytes, _ publicKey: Bytes) -> Bytes {
        let own = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        let peer = try! Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        return try! own.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Array($0) }
    }
}

public struct CipherState: Sendable {
    public private(set) var key: Bytes?
    public var nonce: UInt64 = 0

    public init(key: Bytes? = nil) { self.key = key }

    public mutating func encrypt(ad: Bytes, _ plaintext: Bytes) -> Bytes {
        guard let key else { return plaintext }
        defer { nonce += 1 }
        return Noise.encrypt(key: key, nonce: nonce, ad: ad, plaintext: plaintext)
    }

    public mutating func decrypt(ad: Bytes, _ ciphertext: Bytes) -> Bytes? {
        guard let key else { return ciphertext }
        guard let plaintext = Noise.decrypt(key: key, nonce: nonce, ad: ad, ciphertext: ciphertext) else {
            return nil
        }
        nonce += 1
        return plaintext
    }
}

public struct SymmetricState: Sendable {
    public private(set) var ck: Bytes
    public private(set) var h: Bytes
    public private(set) var cipher = CipherState()

    public init(protocolName: String) {
        let name = Bytes(protocolName.utf8)
        h = name.count <= Noise.hashLength
            ? name + Bytes(repeating: 0, count: Noise.hashLength - name.count)
            : Noise.hash(name)
        ck = h
    }

    public mutating func mixKey(_ inputKeyMaterial: Bytes) {
        let out = Noise.hkdf(ck, inputKeyMaterial, outputs: 2)
        ck = out[0]
        cipher = CipherState(key: out[1])
    }

    public mutating func mixHash(_ data: Bytes) { h = Noise.hash(h + data) }

    public mutating func mixKeyAndHash(_ inputKeyMaterial: Bytes) {
        let out = Noise.hkdf(ck, inputKeyMaterial, outputs: 3)
        ck = out[0]
        mixHash(out[1])
        cipher = CipherState(key: out[2])
    }

    public mutating func encryptAndHash(_ plaintext: Bytes) -> Bytes {
        let ciphertext = cipher.encrypt(ad: h, plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    public mutating func decryptAndHash(_ ciphertext: Bytes) -> Bytes? {
        guard let plaintext = cipher.decrypt(ad: h, ciphertext) else { return nil }
        mixHash(ciphertext)
        return plaintext
    }

    /// The first state encrypts from initiator to responder, the second the other way.
    public func split() -> (CipherState, CipherState) {
        let out = Noise.hkdf(ck, [], outputs: 2)
        return (CipherState(key: out[0]), CipherState(key: out[1]))
    }
}

/// A line of a handshake trace: a step, or a value that step produced.
public enum TraceLine: Sendable, Equatable {
    case step(String)
    case value(String, Bytes)
}

/// One side of `NNpsk0`:
///
///     -> psk, e
///     <- e, ee
///
/// Ephemeral keys are injected so that every value is reproducible. Each side records the
/// intermediate values it computes, which is what the worked examples print.
public struct NNpsk0: Sendable {
    public enum Role: Sendable { case initiator, responder }

    public let role: Role
    public let ephemeralPublic: Bytes
    public private(set) var symmetric: SymmetricState
    public private(set) var remoteEphemeral: Bytes?
    public private(set) var trace: [TraceLine] = []
    private let psk: Bytes
    private let ephemeralPrivate: Bytes

    public init(role: Role, prologue: Bytes, psk: Bytes, ephemeralPrivate: Bytes) {
        precondition(psk.count == 32)
        self.role = role
        self.psk = psk
        self.ephemeralPrivate = ephemeralPrivate
        ephemeralPublic = Noise.publicKey(ephemeralPrivate)
        symmetric = SymmetricState(protocolName: Noise.protocolName)
        trace += [.step("InitializeSymmetric(protocol_name)"), .value("h", symmetric.h), .value("ck", symmetric.ck)]
        symmetric.mixHash(prologue)
        trace += [.step("MixHash(prologue)"), .value("h", symmetric.h)]
    }

    public var handshakeHash: Bytes { symmetric.h }

    /// `-> psk, e` and the payload, as the initiator sends it: `e.public ‖ ciphertext`.
    public mutating func writeMessageA(payload: Bytes) -> Bytes {
        precondition(role == .initiator)
        mixPsk()
        mixEphemeral(ephemeralPublic)
        let ciphertext = symmetric.encryptAndHash(payload)
        trace += [.step("EncryptAndHash(payload)"), .value("h", symmetric.h)]
        return ephemeralPublic + ciphertext
    }

    public mutating func readMessageA(_ message: Bytes) -> Bytes? {
        precondition(role == .responder)
        guard message.count >= Noise.dhLength + Noise.tagLength else { return nil }
        mixPsk()
        let remote = Array(message[0..<Noise.dhLength])
        remoteEphemeral = remote
        mixEphemeral(remote)
        guard let payload = symmetric.decryptAndHash(Array(message[Noise.dhLength...])) else { return nil }
        trace += [.step("DecryptAndHash(payload)"), .value("h", symmetric.h)]
        return payload
    }

    /// `<- e, ee` and the payload, as the responder sends it: `e.public ‖ ciphertext`.
    public mutating func writeMessageB(payload: Bytes) -> Bytes {
        precondition(role == .responder && remoteEphemeral != nil)
        mixEphemeral(ephemeralPublic)
        mixEphemeralDH()
        let ciphertext = symmetric.encryptAndHash(payload)
        trace += [.step("EncryptAndHash(payload)"), .value("h", symmetric.h)]
        return ephemeralPublic + ciphertext
    }

    public mutating func readMessageB(_ message: Bytes) -> Bytes? {
        precondition(role == .initiator)
        guard message.count >= Noise.dhLength + Noise.tagLength else { return nil }
        let remote = Array(message[0..<Noise.dhLength])
        remoteEphemeral = remote
        mixEphemeral(remote)
        mixEphemeralDH()
        guard let payload = symmetric.decryptAndHash(Array(message[Noise.dhLength...])) else { return nil }
        trace += [.step("DecryptAndHash(payload)"), .value("h", symmetric.h)]
        return payload
    }

    /// The transport cipher states: initiator to responder, then responder to initiator.
    public func split() -> (CipherState, CipherState) { symmetric.split() }

    private mutating func mixPsk() {
        symmetric.mixKeyAndHash(psk)
        trace += [
            .step("psk: MixKeyAndHash(psk)"), .value("ck", symmetric.ck), .value("h", symmetric.h),
            .value("k", symmetric.cipher.key!),
        ]
    }

    /// In a handshake with a PSK, every `e` is also mixed into the key, not only the hash.
    private mutating func mixEphemeral(_ publicKey: Bytes) {
        symmetric.mixHash(publicKey)
        symmetric.mixKey(publicKey)
        trace += [
            .step("e: MixHash(e.public), MixKey(e.public)"), .value("e.public", publicKey),
            .value("ck", symmetric.ck), .value("h", symmetric.h), .value("k", symmetric.cipher.key!),
        ]
    }

    private mutating func mixEphemeralDH() {
        let shared = Noise.dh(ephemeralPrivate, remoteEphemeral!)
        symmetric.mixKey(shared)
        trace += [
            .step("ee: MixKey(DH(e, re))"), .value("DH(e, re)", shared), .value("ck", symmetric.ck),
            .value("k", symmetric.cipher.key!),
        ]
    }
}

/// Renders trace lines as the worked examples show them: steps flush left, values indented
/// with their hex in one column.
public func renderTrace(_ lines: [TraceLine]) -> String {
    let width = lines.reduce(0) { width, line in
        if case .value(let label, _) = line { return max(width, label.count) }
        return width
    }
    return lines.map { line in
        switch line {
        case .step(let text):
            return text
        case .value(let label, let bytes):
            return "  " + label + String(repeating: " ", count: width - label.count + 2) + bytes.hex
        }
    }.joined(separator: "\n")
}

/// Renders labelled values in two columns, the way the key tables in the examples read.
public func renderLabelled(_ rows: [(String, Bytes)]) -> String {
    let width = rows.map(\.0.count).max() ?? 0
    return rows.map { label, bytes in
        label + String(repeating: " ", count: width - label.count + 2) + bytes.hex
    }.joined(separator: "\n")
}
