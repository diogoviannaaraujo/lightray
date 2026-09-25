import Foundation
import Testing

@testable import LightrayVectors

private struct Fixture: Decodable {
    struct Vector: Decodable {
        struct Message: Decodable {
            let payload: String
            let ciphertext: String
        }

        let protocol_name: String
        let init_prologue: String
        let init_psks: [String]
        let init_ephemeral: String
        let resp_prologue: String
        let resp_psks: [String]
        let resp_ephemeral: String
        let handshake_hash: String
        let messages: [Message]
    }

    let vector: Vector
}

@Test func noiseMatchesThePublishedVector() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/cacophony-Noise_NNpsk0_25519_AESGCM_SHA256.json")
    let vector = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).vector
    #expect(vector.protocol_name == Noise.protocolName)

    var initiator = NNpsk0(
        role: .initiator, prologue: Bytes(hex: vector.init_prologue), psk: Bytes(hex: vector.init_psks[0]),
        ephemeralPrivate: Bytes(hex: vector.init_ephemeral))
    var responder = NNpsk0(
        role: .responder, prologue: Bytes(hex: vector.resp_prologue), psk: Bytes(hex: vector.resp_psks[0]),
        ephemeralPrivate: Bytes(hex: vector.resp_ephemeral))

    let first = vector.messages[0], second = vector.messages[1]
    let messageA = initiator.writeMessageA(payload: Bytes(hex: first.payload))
    #expect(messageA.hex == first.ciphertext)
    #expect(responder.readMessageA(messageA) == Bytes(hex: first.payload))
    let messageB = responder.writeMessageB(payload: Bytes(hex: second.payload))
    #expect(messageB.hex == second.ciphertext)
    #expect(initiator.readMessageB(messageB) == Bytes(hex: second.payload))
    #expect(initiator.handshakeHash.hex == vector.handshake_hash)
    #expect(responder.handshakeHash.hex == vector.handshake_hash)

    // Transport messages keep alternating, starting with the initiator.
    var (initiatorSend, initiatorReceive) = initiator.split()
    var (responderReceive, responderSend) = responder.split()
    for (index, message) in vector.messages.enumerated().dropFirst(2) {
        let payload = Bytes(hex: message.payload)
        if index % 2 == 0 {
            let sealed = initiatorSend.encrypt(ad: [], payload)
            #expect(sealed.hex == message.ciphertext)
            #expect(responderReceive.decrypt(ad: [], sealed) == payload)
        } else {
            let sealed = responderSend.encrypt(ad: [], payload)
            #expect(sealed.hex == message.ciphertext)
            #expect(initiatorReceive.decrypt(ad: [], sealed) == payload)
        }
    }
}

@Test func x25519MatchesRFC7748() {
    let alice = Bytes(hex: "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
    let bob = Bytes(hex: "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
    #expect(Noise.publicKey(alice).hex == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
    #expect(Noise.publicKey(bob).hex == "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
    #expect(
        Noise.dh(alice, Noise.publicKey(bob)).hex
            == "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
}

@Test func x25519MatchesVersion0Example() {
    let client = Bytes(repeating: 0x11, count: 32)
    let host = Bytes(repeating: 0x22, count: 32)
    #expect(Noise.publicKey(client).hex == "7b4e909bbe7ffe44c465a220037d608ee35897d31ef972f07f74892cb0f73f13")
    #expect(Noise.publicKey(host).hex == "0faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20")
    #expect(
        Noise.dh(client, Noise.publicKey(host)).hex
            == "9e004098efc091d4ec2663b4e9f5cfd4d7064571690b4bea97ab146ab9f35056")
}

@Test func protocolNameIsExactlyOneHashLong() {
    #expect(Bytes(Noise.protocolName.utf8).count == Noise.hashLength)
    #expect(SymmetricState(protocolName: Noise.protocolName).h == Bytes(Noise.protocolName.utf8))
}
