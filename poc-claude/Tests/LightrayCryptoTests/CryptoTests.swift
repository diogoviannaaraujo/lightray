import CryptoKit
import LightrayCore
import LightrayCrypto
import Testing

@Suite("Crypto")
struct CryptoTests {
    static let psk = SymmetricKey(data: [UInt8](repeating: 0x42, count: 32))

    /// `DirectionKeys` expects exactly `key[16] || iv[12]`, which is what the
    /// key schedule's HKDF output is.
    static func randomDirectionKeys() -> DirectionKeys {
        DirectionKeys(SymmetricKey(data: (0..<KeySchedule.outputSize).map { _ in UInt8.random(in: 0...255) }))
    }

    static func makeInit(psk: SymmetricKey = CryptoTests.psk, pairingID: UInt64 = 0xA11CE,
                         resuming: UInt32? = nil)
        throws -> (initiator: HandshakeInitiator, bytes: [UInt8]) {
        var body = InitBody()
        body.capabilities = [.ltr]
        body.streams = [StreamDescriptor(id: 1, kind: .video, direction: .hostToClient, streamClass: .media)]
        body.clientTimestamp = 1_000
        body.resumeSessionID = resuming
        let initiator = HandshakeInitiator(psk: psk, pairingID: pairingID, body: body)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 2048, alignment: 64)
        defer { buffer.deallocate() }
        let length = try initiator.writeInit(into: buffer, maxDatagramSize: 1200)
        return (initiator, Array(UnsafeRawBufferPointer(rebasing: buffer[..<length])))
    }

    @Test func aFullHandshakeAgreesOnKeys() throws {
        let (initiator, initBytes) = try Self.makeInit()
        #expect(initBytes.count == 1200, "the INIT is padded to max_datagram_size")

        let responder = HandshakeResponder(psk: Self.psk)
        let accepted = try initBytes.withUnsafeBytes { try responder.receiveInit($0) }
        #expect(accepted.pairingID == 0xA11CE)
        #expect(accepted.body.streams.count == 1)
        #expect(accepted.body.capabilities == [.ltr])

        var response = ResponseBody()
        response.acceptedCapabilities = [.ltr]
        response.streams = accepted.body.streams
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 2048, alignment: 64)
        defer { buffer.deallocate() }
        let written = try responder.writeResponse(into: buffer, accepted: accepted,
                                                  sessionID: 0x1234_5678, body: response)
        // The reply must be far smaller than the INIT, so the handshake cannot
        // be used for amplification.
        #expect(written.length < initBytes.count / 4, "RESPONSE is \(written.length) bytes")

        let result = try initiator.receiveResponse(UnsafeRawBufferPointer(rebasing: buffer[..<written.length]))
        #expect(result.sessionID == 0x1234_5678)
        #expect(result.body.acceptedCapabilities == [.ltr])

        // Both sides derived the same traffic keys: seal on one, open on the other.
        let client = PacketProtection(send: result.keys.clientToHost, receive: result.keys.hostToClient)
        let host = PacketProtection(send: written.keys.hostToClient, receive: written.keys.clientToHost)
        try Self.expectRoundTrip(from: client, to: host)
        try Self.expectRoundTrip(from: host, to: client)
    }

    static func expectRoundTrip(from sender: PacketProtection, to receiver: PacketProtection,
                                packetNumber: UInt64 = 7) throws {
        let header = UnsafeMutableRawBufferPointer.allocate(byteCount: Wire.headerSize, alignment: 16)
        let plaintext = UnsafeMutableRawBufferPointer.allocate(byteCount: 64, alignment: 16)
        let sealed = UnsafeMutableRawBufferPointer.allocate(byteCount: 256, alignment: 16)
        let opened = UnsafeMutableRawBufferPointer.allocate(byteCount: 256, alignment: 16)
        defer { header.deallocate(); plaintext.deallocate(); sealed.deallocate(); opened.deallocate() }
        header.initializeMemory(as: UInt8.self, repeating: 0x11)
        plaintext.initializeMemory(as: UInt8.self, repeating: 0xAB)
        let n = sender.seal(plaintext: UnsafeRawBufferPointer(plaintext),
                            header: UnsafeRawBufferPointer(header),
                            packetNumber: packetNumber, into: sealed)
        #expect(n == 64 + Wire.tagSize)
        let m = receiver.open(sealed: UnsafeRawBufferPointer(rebasing: sealed[..<n!]),
                              header: UnsafeRawBufferPointer(header),
                              packetNumber: packetNumber, into: opened)
        #expect(m == 64)
    }

    @Test func aVersionMismatchIsDroppedNotNegotiated() throws {
        var (_, bytes) = try Self.makeInit()
        bytes[1] = 7    // a version that pins different codecs
        let responder = HandshakeResponder(psk: Self.psk)
        #expect(throws: HandshakeError.versionMismatch(7)) {
            try bytes.withUnsafeBytes { try responder.receiveInit($0) }
        }
    }

    @Test func theWrongPSKFailsToOpenTheINIT() throws {
        let (_, bytes) = try Self.makeInit()
        let wrong = HandshakeResponder(psk: SymmetricKey(data: [UInt8](repeating: 0x43, count: 32)))
        #expect(throws: HandshakeError.authenticationFailed) {
            try bytes.withUnsafeBytes { try wrong.receiveInit($0) }
        }
    }

    @Test func aTamperedINITPrefixFailsBecauseItIsTheAAD() throws {
        for index in [2, 5, 20, 43] {      // reserved, pairing id, ephemeral key
            var (_, bytes) = try Self.makeInit()
            bytes[index] ^= 0x01
            let responder = HandshakeResponder(psk: Self.psk)
            #expect(throws: HandshakeError.authenticationFailed) {
                try bytes.withUnsafeBytes { try responder.receiveInit($0) }
            }
        }
    }

    @Test func aTamperedINITBodyFails() throws {
        var (_, bytes) = try Self.makeInit()
        bytes[100] ^= 0x01
        let responder = HandshakeResponder(psk: Self.psk)
        #expect(throws: HandshakeError.authenticationFailed) {
            try bytes.withUnsafeBytes { try responder.receiveInit($0) }
        }
    }

    @Test func aReplayedINITIsRejected() throws {
        let (_, bytes) = try Self.makeInit()
        let responder = HandshakeResponder(psk: Self.psk)
        _ = try bytes.withUnsafeBytes { try responder.receiveInit($0) }
        // The same ephemeral key twice is a replay: the key is fresh for every
        // handshake, which is a stronger guard than a timestamp, and it survives
        // a client reboot resetting its monotonic clock.
        #expect(throws: HandshakeError.replayed) {
            try bytes.withUnsafeBytes { try responder.receiveInit($0) }
        }
        // A genuinely new handshake from the same pairing still works.
        let (_, fresh) = try Self.makeInit()
        _ = try fresh.withUnsafeBytes { try responder.receiveInit($0) }
    }

    @Test func aTamperedHeaderOrBodyOrPacketNumberIsRejected() throws {
        let keys = Self.randomDirectionKeys()
        let protection = PacketProtection(send: keys, receive: keys)
        let header = UnsafeMutableRawBufferPointer.allocate(byteCount: Wire.headerSize, alignment: 16)
        let plaintext = UnsafeMutableRawBufferPointer.allocate(byteCount: 1168, alignment: 16)
        let sealed = UnsafeMutableRawBufferPointer.allocate(byteCount: 2048, alignment: 16)
        let opened = UnsafeMutableRawBufferPointer.allocate(byteCount: 2048, alignment: 16)
        defer { header.deallocate(); plaintext.deallocate(); sealed.deallocate(); opened.deallocate() }
        header.initializeMemory(as: UInt8.self, repeating: 0x11)
        plaintext.initializeMemory(as: UInt8.self, repeating: 0xCD)

        let n = protection.seal(plaintext: UnsafeRawBufferPointer(plaintext),
                                header: UnsafeRawBufferPointer(header),
                                packetNumber: 42, into: sealed)!
        #expect(n == 1168 + Wire.tagSize)
        let view = UnsafeRawBufferPointer(rebasing: sealed[..<n])

        #expect(protection.open(sealed: view, header: UnsafeRawBufferPointer(header),
                                packetNumber: 42, into: opened) == 1168)

        // The 16-byte header is authenticated as AAD, so changing it fails.
        header[3] ^= 1
        #expect(protection.open(sealed: view, header: UnsafeRawBufferPointer(header),
                                packetNumber: 42, into: opened) == nil)
        header[3] ^= 1

        // The nonce is the IV XOR the full packet number, so a wrong number fails.
        #expect(protection.open(sealed: view, header: UnsafeRawBufferPointer(header),
                                packetNumber: 43, into: opened) == nil)

        sealed[100] ^= 1
        #expect(protection.open(sealed: view, header: UnsafeRawBufferPointer(header),
                                packetNumber: 42, into: opened) == nil)
    }

    @Test func nonceUniquenessAcrossPacketNumbers() throws {
        let keys = Self.randomDirectionKeys()
        let protection = PacketProtection(send: keys, receive: keys)
        let header = UnsafeMutableRawBufferPointer.allocate(byteCount: Wire.headerSize, alignment: 16)
        let plaintext = UnsafeMutableRawBufferPointer.allocate(byteCount: 32, alignment: 16)
        let sealed = UnsafeMutableRawBufferPointer.allocate(byteCount: 256, alignment: 16)
        defer { header.deallocate(); plaintext.deallocate(); sealed.deallocate() }
        header.initializeMemory(as: UInt8.self, repeating: 0)
        plaintext.initializeMemory(as: UInt8.self, repeating: 0)

        // Identical plaintext under different packet numbers must not produce
        // identical ciphertext, which is what a repeated nonce would look like.
        var seen = Set<[UInt8]>()
        for pn in [0, 1, 2, 0xFFFF_FFFF, 0x1_0000_0000, 0xFFFF_FFFF_FFFF] as [UInt64] {
            let n = protection.seal(plaintext: UnsafeRawBufferPointer(plaintext),
                                    header: UnsafeRawBufferPointer(header),
                                    packetNumber: pn, into: sealed)!
            seen.insert(Array(UnsafeRawBufferPointer(rebasing: sealed[..<n])))
        }
        #expect(seen.count == 6, "every packet number produced distinct ciphertext")
    }

    @Test func theReplayWindowTolerates2048PacketsOfReordering() {
        // 2048 bits tolerates 19.7 ms of reordering at 1 Gbps and 393 ms at
        // 50 Mbps, which is far more than any path this protocol targets.
        var window = ReplayWindow()
        #expect(ReplayWindow.width == 2048)

        let base: UInt64 = 100_000
        let first = window.accept(base)
        let duplicate = window.accept(base)
        let reordered = window.accept(base - 1)
        let oldestInWindow = window.accept(base - 2047)
        let pastTheWindow = window.accept(base - 2048)
        #expect(first)
        #expect(!duplicate, "a duplicate is rejected")
        #expect(reordered, "reordering inside the window is fine")
        #expect(oldestInWindow)
        #expect(!pastTheWindow, "past the window it is rejected")

        let jumped = window.accept(base + 10_000)
        let stale = window.accept(base)
        #expect(jumped, "a jump forward slides the window")
        #expect(!stale, "and leaves the old numbers behind")
        #expect(window.highest == base + 10_000)
        #expect(window.isReplay(base + 10_000))
        #expect(!window.isReplay(base + 10_001))

        window.reset()
        let afterReset = window.accept(1)
        #expect(afterReset, "a rekey starts a fresh window")
    }

    @Test func theStatelessResetTokenIsAnHMACOfTheSessionID() {
        let secret = SymmetricKey(size: .bits256)
        let token = KeySchedule.resetToken(hostSecret: secret, sessionID: 4242)
        #expect(token.count == 16)
        #expect(KeySchedule.verifyResetToken(token, hostSecret: secret, sessionID: 4242))
        #expect(!KeySchedule.verifyResetToken(token, hostSecret: secret, sessionID: 4243),
                "a token for another session does not verify")
        let other = SymmetricKey(size: .bits256)
        #expect(!KeySchedule.verifyResetToken(token, hostSecret: other, sessionID: 4242),
                "and neither does one from another host")
        // Deterministic, so a host that keeps no per-session state can still
        // answer for a session it has forgotten.
        #expect(KeySchedule.resetToken(hostSecret: secret, sessionID: 4242) == token)
    }

    @Test func theKeyScheduleIsDeterministicAndBoundToItsTranscript() {
        let ephemeral = (0..<32).map { UInt8(truncatingIfNeeded: $0) }
        let t0 = KeySchedule.transcript0(version: 0, pairingID: 1, clientEphemeral: ephemeral)
        #expect(t0.count == 32)
        #expect(KeySchedule.transcript0(version: 0, pairingID: 1, clientEphemeral: ephemeral) == t0,
                "the same inputs give the same transcript")
        #expect(KeySchedule.transcript0(version: 0, pairingID: 2, clientEphemeral: ephemeral) != t0,
                "a different pairing gives a different one")
        #expect(KeySchedule.transcript0(version: 1, pairingID: 1, clientEphemeral: ephemeral) != t0,
                "and so does a different version")
        let t1 = KeySchedule.transcript1(transcript0: t0, hostEphemeral: ephemeral, sessionID: 5)
        #expect(t1 != KeySchedule.transcript1(transcript0: t0, hostEphemeral: ephemeral, sessionID: 6),
                "the session id is bound into the traffic keys")
    }

    @Test func theInitKeyDependsOnlyOnThePSKAndTranscript() {
        let ephemeral = (0..<32).map { UInt8(truncatingIfNeeded: $0) }
        let t0 = KeySchedule.transcript0(version: 0, pairingID: 1, clientEphemeral: ephemeral)
        let a = KeySchedule.initKeys(psk: Self.psk, transcript0: t0)
        let b = KeySchedule.initKeys(psk: Self.psk, transcript0: t0)
        #expect(a.ivHigh == b.ivHigh && a.ivLow == b.ivLow)
        // The host can derive it too, which is the whole point: it has no
        // ephemeral of its own when the INIT arrives.
        let other = KeySchedule.initKeys(psk: SymmetricKey(data: [UInt8](repeating: 9, count: 32)),
                                         transcript0: t0)
        #expect(other.ivLow != a.ivLow)
    }
}
