import CryptoKit
import Foundation
import Testing

@testable import LightrayCore

/// Reproduces `tools/vectors/vectors.json`, the worked examples of `docs/handshake.md` and
/// `docs/packets.md`, from their stated inputs.
struct Vectors {
    let json: [String: Any]

    init() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("tools/vectors/vectors.json"))
        json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func section(_ path: String...) -> [String: Any] {
        path.reduce(json) { $0[$1] as! [String: Any] }
    }

    func bytes(_ dict: [String: Any], _ key: String) -> Bytes { Bytes(hex: dict[key] as! String)! }

    func number(_ dict: [String: Any], _ key: String) -> UInt64 {
        if let n = dict[key] as? NSNumber { return n.uint64Value }
        return UInt64(dict[key] as! String, radix: 16)!
    }
}

@Test func handshakeWorkedExample() throws {
    let v = try Vectors()
    let inputs = v.section("handshake", "inputs")
    let outputs = v.section("handshake", "outputs")
    let psk = v.bytes(inputs, "psk")
    let pairingID = UInt64(inputs["pairing_id"] as! String, radix: 16)!
    let clientEphemeral = try Curve25519.KeyAgreement.PrivateKey(
        rawRepresentation: v.bytes(inputs, "client_ephemeral_private"))
    let hostEphemeral = try Curve25519.KeyAgreement.PrivateKey(
        rawRepresentation: v.bytes(inputs, "host_ephemeral_private"))

    // The client's INIT, built from parameters parsed out of the vector's own bytes.
    let initParams = try HandshakeParams.decode(v.bytes(inputs, "init_params")[...])
    #expect(initParams.encoded == v.bytes(inputs, "init_params"))
    let client = ClientHandshake(psk: psk, pairingID: pairingID, params: initParams, ephemeral: clientEphemeral)
    #expect(client.datagram == v.bytes(outputs, "init"))

    // The host opens it and answers.
    let opened = try OpenedInit.open(client.datagram) { $0 == pairingID ? psk : nil }
    #expect(opened.params == initParams)
    try opened.validate(unixTime: initParams.timestamp! + 5)
    let sessionID = UInt32(v.number(inputs, "session_id"))
    let token = Handshake.resetToken(hostSecret: v.bytes(inputs, "host_secret"), sessionID: sessionID)
    #expect(token == v.bytes(outputs, "reset_token"))
    let responseParams = try HandshakeParams.decode(v.bytes(inputs, "response_params")[...])
    let accepted = try #require(
        opened.respond(sessionID: sessionID, resetToken: token, params: responseParams, ephemeral: hostEphemeral))
    #expect(accepted.response == v.bytes(outputs, "response"))
    #expect(accepted.handshakeHash == v.bytes(outputs, "handshake_hash"))
    #expect(accepted.receiveKey == v.bytes(outputs, "client_to_host_key"))
    #expect(accepted.sendKey == v.bytes(outputs, "host_to_client_key"))

    // The client opens the RESPONSE.
    let result = try #require(try client.open(accepted.response))
    #expect(result.sessionID == sessionID)
    #expect(result.resetToken == token)
    #expect(result.sendKey == v.bytes(outputs, "client_to_host_key"))
    #expect(result.receiveKey == v.bytes(outputs, "host_to_client_key"))
    #expect(result.handshakeHash == v.bytes(outputs, "handshake_hash"))

    #expect(Handshake.sessionUnknown(sessionID: sessionID, token: token) == v.bytes(outputs, "session_unknown"))
}

@Test(arguments: [2, 3, 4, 11])
func everyCleartextInitByteIsAuthenticated(offset: Int) throws {
    let v = try Vectors()
    let inputs = v.section("handshake", "inputs")
    var datagram = v.bytes(v.section("handshake", "outputs"), "init")
    datagram[offset] ^= 1
    let psk = v.bytes(inputs, "psk")
    #expect(throws: HandshakeError.self) { try OpenedInit.open(datagram) { _ in psk } }
}

@Test func responseThatFailsToOpenChangesNothing() throws {
    let v = try Vectors()
    let inputs = v.section("handshake", "inputs")
    let outputs = v.section("handshake", "outputs")
    let client = ClientHandshake(
        psk: v.bytes(inputs, "psk"), pairingID: UInt64(inputs["pairing_id"] as! String, radix: 16)!,
        params: try HandshakeParams.decode(v.bytes(inputs, "init_params")[...]),
        ephemeral: try .init(rawRepresentation: v.bytes(inputs, "client_ephemeral_private")))
    var forged = v.bytes(outputs, "response")
    forged[forged.count - 1] ^= 1
    #expect(try client.open(forged) == nil)
    #expect(try client.open(v.bytes(outputs, "response"))?.sessionID == UInt32(v.number(inputs, "session_id")))
}

@Test func packetNumberReconstruction() throws {
    let v = try Vectors()
    for row in v.json["packet_numbers"] as! [[String: Any]] {
        let expected = v.number(row, "expected")
        let seq = UInt32(v.number(row, "transport_seq"))
        #expect(Packet.reconstruct(expected: expected, transportSeq: seq) == v.number(row, "packet_number"))
    }
    #expect(Packet.reconstruct(expected: UInt64.max - 5, transportSeq: 0) == UInt64.max - 0xffff_ffff)
}

@Test func protectedDatagramWorkedExample() throws {
    let v = try Vectors()
    let inputs = v.section("protected_datagram", "inputs")
    let outputs = v.section("protected_datagram", "outputs")
    let pn = v.number(inputs, "packet_number")
    let header = ProtectedHeader(
        sessionID: UInt32(v.number(inputs, "session_id")), transportSeq: UInt32(pn),
        sendTimeMicros: UInt32(v.number(inputs, "send_time_us")))
    #expect(header.bytes == v.bytes(outputs, "header"))
    #expect(Chunk.close(.goingAway).encoded == v.bytes(inputs, "chunks"))
    let key = TrafficKey(v.bytes(inputs, "key"))
    let datagram = Packet.seal(header: header, packetNumber: pn, key: key, chunks: v.bytes(inputs, "chunks"))
    #expect(datagram == v.bytes(outputs, "datagram"))
    #expect(Packet.open(datagram, packetNumber: pn, key: key) == v.bytes(inputs, "chunks"))
    #expect(Packet.open(datagram, packetNumber: pn + 1, key: key) == nil)
}

@Test func replayWindow() {
    var w = ReplayWindow()
    #expect(w.expected == 0)
    #expect(w.accepts(0))
    w.record(0)
    #expect(!w.accepts(0))
    w.record(5)
    #expect(w.expected == 6)
    #expect(w.accepts(3))
    w.record(3)
    #expect(!w.accepts(3))
    w.record(5000)
    #expect(!w.accepts(5000 - 2048))
    #expect(w.accepts(5000 - 2047))
    #expect(!w.accepts(5))
}
