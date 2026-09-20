import CryptoKit
import Foundation
import LightrayCore

/// The NNpsk0-shaped key schedule.
///
/// The pairing PSK, both ephemeral X25519 keys and DH(e_c, e_h) feed HKDF-SHA256
/// over a running transcript hash, which yields separate AES-128-GCM key/IV pairs
/// per direction. Phase 0 measured the whole thing at about 96 µs per handshake.
///
/// Normative labels and order (a non-Swift implementation must match exactly):
/// ```
/// transcript0 = SHA256("lightray/v0 init" || version || pairing_id_be || e_c)
/// init_keys   = HKDF(ikm: psk, salt: transcript0, info: "lightray init", L: 28)
/// transcript1 = SHA256(transcript0 || e_h || session_id_be)
/// prk         = HKDF-Extract(salt: transcript1, ikm: X25519(e_c, e_h) || psk)
/// resp_keys   = HKDF-Expand(prk, info: "lightray response", L: 28)
/// c2h_keys    = HKDF-Expand(prk, info: "lightray c2h", L: 28)
/// h2c_keys    = HKDF-Expand(prk, info: "lightray h2c", L: 28)
/// ```
/// Each 28-byte output is `key[16] || iv[12]`.
public enum KeySchedule {
    public static let keySize = 16
    public static let ivSize = 12
    public static let outputSize = keySize + ivSize

    static let initLabel = Array("lightray init".utf8)
    static let responseLabel = Array("lightray response".utf8)
    static let clientToHostLabel = Array("lightray c2h".utf8)
    static let hostToClientLabel = Array("lightray h2c".utf8)
    static let transcriptPrefix = Array("lightray/v0 init".utf8)

    /// `transcript0`, bound to the INIT's cleartext prefix fields.
    public static func transcript0(version: UInt8, pairingID: UInt64, clientEphemeral: [UInt8]) -> [UInt8] {
        var h = SHA256()
        h.update(data: transcriptPrefix)
        h.update(data: [version])
        h.update(data: withUnsafeBytes(of: pairingID.bigEndian) { Array($0) })
        h.update(data: clientEphemeral)
        return Array(h.finalize())
    }

    public static func transcript1(transcript0: [UInt8], hostEphemeral: [UInt8], sessionID: UInt32) -> [UInt8] {
        var h = SHA256()
        h.update(data: transcript0)
        h.update(data: hostEphemeral)
        h.update(data: withUnsafeBytes(of: sessionID.bigEndian) { Array($0) })
        return Array(h.finalize())
    }

    /// The key that protects the INIT body: PSK only, because the host has no
    /// ephemeral of its own yet. No forward secrecy, which is why it carries
    /// nothing but capabilities and configuration.
    public static func initKeys(psk: SymmetricKey, transcript0: [UInt8]) -> DirectionKeys {
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: psk, salt: transcript0)
        let out = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: initLabel, outputByteCount: outputSize)
        return DirectionKeys(out)
    }

    public struct Established {
        public var response: DirectionKeys
        public var clientToHost: DirectionKeys
        public var hostToClient: DirectionKeys
    }

    /// Mixes in DH(e_c, e_h) and derives the response and both traffic key pairs.
    public static func established(psk: SymmetricKey, shared: SharedSecret, transcript1: [UInt8]) -> Established {
        // ikm = dh || psk, so an attacker needs both the pairing secret and the
        // ephemeral private key.
        var ikm = shared.withUnsafeBytes { Array($0) }
        psk.withUnsafeBytes { ikm.append(contentsOf: Array($0)) }
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ikm), salt: transcript1)
        return Established(
            response: DirectionKeys(HKDF<SHA256>.expand(pseudoRandomKey: prk, info: responseLabel, outputByteCount: outputSize)),
            clientToHost: DirectionKeys(HKDF<SHA256>.expand(pseudoRandomKey: prk, info: clientToHostLabel, outputByteCount: outputSize)),
            hostToClient: DirectionKeys(HKDF<SHA256>.expand(pseudoRandomKey: prk, info: hostToClientLabel, outputByteCount: outputSize))
        )
    }

    /// Stateless-reset token: HMAC-SHA256 of the host secret over the session id,
    /// truncated to 16 bytes. Lets the host answer an unknown session without
    /// keeping any state for it.
    public static func resetToken(hostSecret: SymmetricKey, sessionID: UInt32) -> [UInt8] {
        let idBytes = withUnsafeBytes(of: sessionID.bigEndian) { Array($0) }
        let mac = HMAC<SHA256>.authenticationCode(for: idBytes, using: hostSecret)
        return Array(mac.prefix(SessionUnknown.tokenSize))
    }

    public static func verifyResetToken(_ token: [UInt8], hostSecret: SymmetricKey, sessionID: UInt32) -> Bool {
        let expected = resetToken(hostSecret: hostSecret, sessionID: sessionID)
        guard token.count == expected.count else { return false }
        // Constant-time compare.
        var diff: UInt8 = 0
        for i in 0..<expected.count { diff |= token[i] ^ expected[i] }
        return diff == 0
    }
}

/// One direction's AES-128-GCM key plus its 12-byte IV, kept split so the nonce
/// can be built by XOR without touching the heap.
public struct DirectionKeys {
    public let key: SymmetricKey
    /// IV as its leading 4 bytes and trailing 8 bytes, in host order.
    public let ivHigh: UInt32
    public let ivLow: UInt64

    public init(_ material: SymmetricKey) {
        let bytes = material.withUnsafeBytes { Array($0) }
        precondition(bytes.count == KeySchedule.outputSize)
        key = SymmetricKey(data: bytes[0..<KeySchedule.keySize])
        let iv = Array(bytes[KeySchedule.keySize...])
        ivHigh = iv[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        ivLow = iv[4..<12].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    public init(key: SymmetricKey, ivHigh: UInt32, ivLow: UInt64) {
        self.key = key; self.ivHigh = ivHigh; self.ivLow = ivLow
    }

    /// Writes `IV ⊕ packet_number` into a 12-byte scratch buffer. The packet
    /// number is the full reconstructed 64 bits, so a nonce never repeats within
    /// a key even though only 32 bits travel on the wire.
    @inline(__always)
    func writeNonce(_ packetNumber: UInt64, into scratch: UnsafeMutableRawBufferPointer) {
        scratch.storeBytes(of: ivHigh.bigEndian, toByteOffset: 0, as: UInt32.self)
        scratch.storeBytes(of: (ivLow ^ packetNumber).bigEndian, toByteOffset: 4, as: UInt64.self)
    }
}
