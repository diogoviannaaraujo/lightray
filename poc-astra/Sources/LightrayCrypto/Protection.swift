import CryptoKit
import Foundation
import LightrayPrimitives
import LightrayWire

public enum CryptoError: Error { case invalidKey, authentication, replay, exhausted, invalidHandshake, expired }
public protocol PacketProtection {
    func seal(_ plaintext: [UInt8], header: [UInt8], packetNumber: UInt64) throws -> [UInt8]
    func open(_ ciphertext: [UInt8], header: [UInt8], packetNumber: UInt64) throws -> [UInt8]
}
public struct AESGCMProtection: PacketProtection, Sendable {
    private let key: SymmetricKey
    private let iv: [UInt8]
    public init(key: [UInt8], iv: [UInt8]) throws {
        guard key.count == 16, iv.count == 12 else { throw CryptoError.invalidKey }
        self.key = SymmetricKey(data: key)
        self.iv = iv
    }
    public func nonce(packetNumber: UInt64) -> [UInt8] {
        var nonce = iv
        for i in 0..<8 { nonce[11 - i] ^= UInt8(truncatingIfNeeded: packetNumber >> (i * 8)) }
        return nonce
    }
    public func seal(_ plaintext: [UInt8], header: [UInt8], packetNumber: UInt64) throws -> [UInt8] {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonce(packetNumber: packetNumber)), authenticating: header)
        return Array(box.ciphertext) + Array(box.tag)
    }
    public func open(_ ciphertext: [UInt8], header: [UInt8], packetNumber: UInt64) throws -> [UInt8] {
        guard ciphertext.count >= 16 else { throw CryptoError.authentication }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce(packetNumber: packetNumber)), ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
        return Array(try AES.GCM.open(box, using: key, authenticating: header))
    }
}
public struct ReplayWindow {
    private var bits = InlineArray<32, UInt64>(repeating: 0)
    public private(set) var highest: UInt64?
    public init() {}
    public func accepts(_ number: UInt64) -> Bool {
        guard let highest else { return true }
        if number > highest { return true }
        guard highest - number < 2048 else { return false }
        let index = Int(number % 2048)
        return bits[index / 64] & (1 << (index % 64)) == 0
    }
    @discardableResult public mutating func commit(_ number: UInt64) -> Bool {
        guard accepts(number) else { return false }
        if let highest, number > highest {
            if number - highest >= 2048 {
                bits = .init(repeating: 0)
            } else {
                for value in (highest + 1)...number {
                    let i = Int(value % 2048)
                    bits[i / 64] &= ~(1 << (i % 64))
                }
            }
        }
        let i = Int(number % 2048)
        bits[i / 64] |= 1 << (i % 64)
        highest = max(highest ?? number, number)
        return true
    }
    public func reconstruct(_ low: UInt32) -> UInt64 {
        guard let highest else { return UInt64(low) }
        let expected = highest == .max ? highest : highest + 1
        var candidate = (expected & 0xffff_ffff_0000_0000) | UInt64(low)
        if candidate <= expected, expected - candidate >= 0x8000_0000, candidate <= .max - 0x1_0000_0000 { candidate += 0x1_0000_0000 } else if candidate > expected, candidate - expected > 0x8000_0000, candidate >= 0x1_0000_0000 { candidate -= 0x1_0000_0000 }
        return candidate
    }
}
public func resetToken(secret: [UInt8], sessionID: UInt32) -> [UInt8] {
    var writer = ByteWriter()
    writer.put(sessionID)
    return Array(HMAC<SHA256>.authenticationCode(for: writer.bytes, using: SymmetricKey(data: secret)).prefix(16))
}
public func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for i in a.indices { difference |= a[i] ^ b[i] }
    return difference == 0
}
public struct SessionKeys: Sendable {
    public var clientToHost: AESGCMProtection
    public var hostToClient: AESGCMProtection
}
private func derive(_ material: [UInt8], salt: [UInt8], label: String, count: Int) -> [UInt8] {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material), salt: salt, info: Array(label.utf8), outputByteCount: count).withUnsafeBytes { Array($0) }
}
private func trafficKeys(psk: [UInt8], shared: SharedSecret, transcript: [UInt8]) throws -> SessionKeys {
    let material = psk + shared.withUnsafeBytes { Array($0) }
    let salt = Array(SHA256.hash(data: transcript))
    let c = derive(material, salt: salt, label: "lightray-v0 client", count: 28)
    let h = derive(material, salt: salt, label: "lightray-v0 host", count: 28)
    return try .init(clientToHost: AESGCMProtection(key: Array(c.prefix(16)), iv: Array(c.suffix(12))), hostToClient: AESGCMProtection(key: Array(h.prefix(16)), iv: Array(h.suffix(12))))
}
public struct HandshakeResult: Sendable {
    public var sessionID: UInt32
    public var pairingID: UInt64
    public var keys: SessionKeys
    public var resetToken: [UInt8]
    public var configuration: Configuration
    public var ltr: Bool
    public var resumeSessionID: UInt32?
    public var streams: [StreamDescriptor]
    public var pipelineIdleAfter: UInt64
    public var graceWindow: UInt64
}
public final class HandshakeInitiator {
    private let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    private let psk: [UInt8]
    private let pairingID: UInt64
    private var initial: [UInt8] = []
    public init(pairingID: UInt64, psk: [UInt8]) throws {
        guard psk.count >= 32 else { throw CryptoError.invalidKey }
        self.pairingID = pairingID
        self.psk = psk
    }
    public func start(configuration: Configuration, timestamp: UInt64, ltr: Bool = true, resumeSessionID: UInt32? = nil, streams: [StreamDescriptor] = StreamDescriptor.defaults) throws -> [UInt8] {
        _ = try configuration.validated()
        var header = ByteWriter()
        header.put(UInt8(0x80))
        header.put(UInt8(0))
        header.put(UInt16(0))
        header.put(pairingID)
        header.bytes += ephemeral.publicKey.rawRepresentation
        var parameters = HandshakeParameters()
        parameters.configuration = configuration
        parameters.timestamp = timestamp
        parameters.ltr = ltr
        parameters.resumeSessionID = resumeSessionID
        parameters.streams = streams
        let encoded = try parameters.encode()
        var body = ByteWriter()
        body.put(UInt16(encoded.count))
        body.bytes += encoded
        let nonce = AES.GCM.Nonce()
        let nonceBytes = nonce.withUnsafeBytes { Array($0) }
        let key = derive(psk, salt: Array(ephemeral.publicKey.rawRepresentation), label: "lightray-v0 init", count: 16)
        let paddedCount = Int(configuration.maxDatagramSize) - header.bytes.count - 12 - 16
        guard body.bytes.count <= paddedCount else { throw WireError.overflow }
        body.bytes += [UInt8](repeating: 0, count: paddedCount - body.bytes.count)
        let box = try AES.GCM.seal(body.bytes, using: SymmetricKey(data: key), nonce: nonce, authenticating: header.bytes)
        initial = header.bytes + nonceBytes + box.ciphertext + box.tag
        return initial
    }
    public func finish(_ packet: [UInt8]) throws -> HandshakeResult {
        guard !initial.isEmpty, packet.count >= 66 else { throw CryptoError.invalidHandshake }
        var r = ByteReader(packet.span.bytes)
        guard try r.u8() == 0x81, try r.u8() == 0 else { throw CryptoError.invalidHandshake }
        let sessionID = try r.u32()
        let publicBytes = try r.take(32).copyBytes()
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicBytes)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: peer)
        let keys = try trafficKeys(psk: psk, shared: shared, transcript: initial + packet.prefix(38))
        let body = try keys.hostToClient.open(Array(packet.dropFirst(38)), header: Array(packet.prefix(38)), packetNumber: 0)
        let parameters = try HandshakeParameters.decode(body.span.bytes)
        guard parameters.resetToken.count == 16, parameters.timestamp == nil else { throw CryptoError.invalidHandshake }
        return .init(sessionID: sessionID, pairingID: pairingID, keys: keys, resetToken: parameters.resetToken, configuration: parameters.configuration, ltr: parameters.ltr, resumeSessionID: nil, streams: parameters.streams, pipelineIdleAfter: parameters.pipelineIdleAfter, graceWindow: parameters.graceWindow)
    }
}
public final class HandshakeResponder {
    private let secret: [UInt8]
    private var recent: [(digest: [UInt8], at: UInt64, response: [UInt8])] = []
    public init(secret: [UInt8]) throws {
        guard secret.count >= 32 else { throw CryptoError.invalidKey }
        self.secret = secret
    }
    public func accept(_ packet: [UInt8], psk: [UInt8], sessionID: UInt32, timestamp: UInt64, pipelineIdleAfter: UInt64 = 60_000_000_000, graceWindow: UInt64 = 1_800_000_000_000) throws -> (packet: [UInt8], result: HandshakeResult?) {
        guard packet.count >= 256, packet.count <= 9000, psk.count >= 32, sessionID != 0 else { throw CryptoError.invalidHandshake }
        var r = ByteReader(packet.span.bytes)
        guard try r.u8() == 0x80, try r.u8() == 0 else { throw CryptoError.invalidHandshake }
        try r.skip(2)
        let pairing = try r.u64()
        let publicBytes = try r.take(32).copyBytes()
        let nonce = try r.take(12).copyBytes()
        let key = derive(psk, salt: publicBytes, label: "lightray-v0 init", count: 16)
        let sealed = r.rest().copyBytes()
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        let plaintext = Array(try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: packet.prefix(44)))
        var b = ByteReader(plaintext.span.bytes)
        var parameters = try HandshakeParameters.decode(try b.take(Int(try b.u16())))
        guard let sent = parameters.timestamp, max(sent, timestamp) - min(sent, timestamp) <= 30 else { throw CryptoError.expired }
        let config = parameters.configuration
        let ltr = parameters.ltr
        let resume = parameters.resumeSessionID
        guard packet.count == Int(config.maxDatagramSize) else { throw CryptoError.invalidHandshake }
        let digest = Array(SHA256.hash(data: packet))
        recent.removeAll { timestamp > $0.at && timestamp - $0.at > 60 }
        if let cached = recent.first(where: { $0.digest == digest }) { return (cached.response, nil) }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicBytes)
        var header = ByteWriter()
        header.put(UInt8(0x81))
        header.put(UInt8(0))
        header.put(sessionID)
        header.bytes += ephemeral.publicKey.rawRepresentation
        let keys = try trafficKeys(psk: psk, shared: ephemeral.sharedSecretFromKeyAgreement(with: peer), transcript: packet + header.bytes)
        let token = resetToken(secret: secret, sessionID: sessionID)
        parameters.timestamp = nil
        parameters.resetToken = token
        parameters.resumeSessionID = nil
        parameters.pipelineIdleAfter = pipelineIdleAfter
        parameters.graceWindow = graceWindow
        let response = header.bytes + (try keys.hostToClient.seal(parameters.encode(), header: header.bytes, packetNumber: 0))
        guard response.count <= packet.count else { throw CryptoError.invalidHandshake }
        if recent.count == 1024 { recent.removeFirst() }
        recent.append((digest, timestamp, response))
        return (response, .init(sessionID: sessionID, pairingID: pairing, keys: keys, resetToken: token, configuration: config, ltr: ltr, resumeSessionID: resume, streams: parameters.streams, pipelineIdleAfter: pipelineIdleAfter, graceWindow: graceWindow))
    }
}
