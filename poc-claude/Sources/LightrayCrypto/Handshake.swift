import CryptoKit
import LightrayCore

/// Both traffic directions' keys, as the handshake produces them.
public struct TrafficKeys {
    public var clientToHost: DirectionKeys
    public var hostToClient: DirectionKeys
}

public enum HandshakeError: Error, Equatable, Sendable {
    /// The host drops the packet silently and bumps a counter.
    case versionMismatch(UInt8)
    case malformed
    /// Wrong PSK, tampered body, or an unpaired client.
    case authenticationFailed
    /// An INIT no newer than one already seen from this pairing.
    case replayed
    case unexpectedPacket
}

// MARK: - Client side

/// Builds the INIT and consumes the RESPONSE. One instance per handshake attempt.
public final class HandshakeInitiator {
    public let pairingID: UInt64
    private let psk: SymmetricKey
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    private var transcript0: [UInt8] = []
    private var prefixBytes: [UInt8] = []

    public private(set) var offered: InitBody

    public init(psk: SymmetricKey, pairingID: UInt64, body: InitBody) {
        self.psk = psk
        self.pairingID = pairingID
        self.offered = body
        self.ephemeral = Curve25519.KeyAgreement.PrivateKey()
    }

    public var clientEphemeral: [UInt8] { Array(ephemeral.publicKey.rawRepresentation) }

    /// Writes a complete INIT datagram, padded to `max_datagram_size`.
    ///
    /// The padding both limits amplification — the RESPONSE is far smaller — and
    /// proves the path MTU, because the socket sets don't-fragment.
    ///
    /// The padding goes *inside* the sealed body, not after it. That way the
    /// sealed length is implied by the datagram length, so no field has to carry
    /// it, and the padding is authenticated: an attacker cannot strip it to make
    /// a smaller packet that still opens.
    public func writeInit(into out: UnsafeMutableRawBufferPointer, maxDatagramSize: Int) throws -> Int {
        let prefix = InitPrefix(pairingID: pairingID, clientEphemeral: clientEphemeral)
        var w = ByteWriter(out)
        try prefix.encode(into: &w)
        prefixBytes = Array(UnsafeRawBufferPointer(rebasing: out[..<w.written]))
        transcript0 = KeySchedule.transcript0(version: Wire.version, pairingID: pairingID,
                                              clientEphemeral: prefix.clientEphemeral)

        // Seal the body with the PSK-derived key, authenticating the prefix.
        let plaintextSize = maxDatagramSize - InitPrefix.size - Wire.tagSize
        guard plaintextSize > 0, out.count >= maxDatagramSize else { throw HandshakeError.malformed }
        let bodyScratch = UnsafeMutableRawBufferPointer.allocate(byteCount: plaintextSize, alignment: 16)
        defer { bodyScratch.deallocate() }
        var bw = ByteWriter(bodyScratch)
        try offered.encode(into: &bw)
        try bw.pad(to: plaintextSize)

        let keys = KeySchedule.initKeys(psk: psk, transcript0: transcript0)
        guard let sealedLength = PacketProtection.sealHandshake(
            body: UnsafeRawBufferPointer(bodyScratch),
            prefix: UnsafeRawBufferPointer(rebasing: out[..<w.written]),
            keys: keys,
            into: UnsafeMutableRawBufferPointer(rebasing: out[w.written...]))
        else { throw HandshakeError.malformed }
        return w.written + sealedLength
    }

    public struct Accepted {
        public var sessionID: UInt32
        public var body: ResponseBody
        public var keys: TrafficKeys
    }

    /// Opens a RESPONSE and derives the traffic keys.
    public func receiveResponse(_ datagram: UnsafeRawBufferPointer) throws -> Accepted {
        guard datagram.count > ResponsePrefix.size + Wire.tagSize else { throw HandshakeError.malformed }
        let prefix: ResponsePrefix
        do {
            let span = RawSpan(_unsafeBytes: datagram)
            var r = ByteReader(span)
            prefix = try ResponsePrefix.decode(&r)
        } catch {
            if case .unsupportedVersion(let v) = error { throw HandshakeError.versionMismatch(v) }
            throw HandshakeError.malformed
        }

        guard let hostPublic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: prefix.hostEphemeral),
              let shared = try? ephemeral.sharedSecretFromKeyAgreement(with: hostPublic)
        else { throw HandshakeError.authenticationFailed }

        let t1 = KeySchedule.transcript1(transcript0: transcript0, hostEphemeral: prefix.hostEphemeral,
                                         sessionID: prefix.sessionID)
        let established = KeySchedule.established(psk: psk, shared: shared, transcript1: t1)

        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: datagram.count, alignment: 16)
        defer { scratch.deallocate() }
        guard let bodyLength = PacketProtection.openHandshake(
            sealed: UnsafeRawBufferPointer(rebasing: datagram[ResponsePrefix.size...]),
            prefix: UnsafeRawBufferPointer(rebasing: datagram[..<ResponsePrefix.size]),
            keys: established.response, into: scratch)
        else { throw HandshakeError.authenticationFailed }

        let body: ResponseBody
        do {
            let span = RawSpan(_unsafeBytes: UnsafeRawBufferPointer(rebasing: scratch[..<bodyLength]))
            var r = ByteReader(span)
            body = try ResponseBody.decode(&r)
        } catch { throw HandshakeError.malformed }

        return Accepted(sessionID: prefix.sessionID, body: body,
                        keys: TrafficKeys(clientToHost: established.clientToHost,
                                          hostToClient: established.hostToClient))
    }
}

// MARK: - Host side

/// Opens INITs and writes RESPONSEs. One instance serves every client of a host.
public final class HandshakeResponder {
    private let psk: SymmetricKey
    private let hostSecret: SymmetricKey
    /// Client ephemerals already seen, newest last.
    ///
    /// This, not the timestamp, is the replay guard: the ephemeral is fresh for
    /// every handshake, so a repeat is a replay, and unlike a timestamp it
    /// survives a client reboot resetting its monotonic clock. The INIT's
    /// timestamp is still carried and surfaced, because a host that wants to
    /// reject stale INITs on a trusted clock can use it.
    private var seenEphemerals: [[UInt8]] = []
    private let maxSeenEphemerals = 512

    public init(psk: SymmetricKey, hostSecret: SymmetricKey = SymmetricKey(size: .bits256)) {
        self.psk = psk
        self.hostSecret = hostSecret
    }

    public struct AcceptedInit {
        public var pairingID: UInt64
        public var clientEphemeral: [UInt8]
        public var body: InitBody
        public var transcript0: [UInt8]
    }

    /// Opens an INIT. A version mismatch and a bad PSK are distinguishable here
    /// but not on the wire: both end with the packet dropped.
    public func receiveInit(_ datagram: UnsafeRawBufferPointer) throws -> AcceptedInit {
        guard datagram.count >= InitPrefix.size + Wire.tagSize else { throw HandshakeError.malformed }
        let prefix: InitPrefix
        do {
            let span = RawSpan(_unsafeBytes: datagram)
            var r = ByteReader(span)
            prefix = try InitPrefix.decode(&r)
        } catch {
            if case .unsupportedVersion(let v) = error { throw HandshakeError.versionMismatch(v) }
            throw HandshakeError.malformed
        }

        let t0 = KeySchedule.transcript0(version: prefix.version, pairingID: prefix.pairingID,
                                         clientEphemeral: prefix.clientEphemeral)
        let keys = KeySchedule.initKeys(psk: psk, transcript0: t0)
        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: datagram.count, alignment: 16)
        defer { scratch.deallocate() }
        guard let bodyLength = PacketProtection.openHandshake(
            sealed: UnsafeRawBufferPointer(rebasing: datagram[InitPrefix.size...]),
            prefix: UnsafeRawBufferPointer(rebasing: datagram[..<InitPrefix.size]),
            keys: keys, into: scratch)
        else { throw HandshakeError.authenticationFailed }

        let body: InitBody
        do {
            let span = RawSpan(_unsafeBytes: UnsafeRawBufferPointer(rebasing: scratch[..<bodyLength]))
            var r = ByteReader(span)
            body = try InitBody.decode(&r)
        } catch { throw HandshakeError.malformed }

        if seenEphemerals.contains(prefix.clientEphemeral) { throw HandshakeError.replayed }
        seenEphemerals.append(prefix.clientEphemeral)
        if seenEphemerals.count > maxSeenEphemerals {
            seenEphemerals.removeFirst(seenEphemerals.count - maxSeenEphemerals)
        }

        return AcceptedInit(pairingID: prefix.pairingID, clientEphemeral: prefix.clientEphemeral,
                            body: body, transcript0: t0)
    }

    public struct Response {
        public var length: Int
        public var keys: TrafficKeys
        public var resetToken: [UInt8]
    }

    /// Writes the RESPONSE for an accepted INIT under `sessionID`, which must
    /// already be chosen because the transcript binds it.
    public func writeResponse(into out: UnsafeMutableRawBufferPointer, accepted: AcceptedInit,
                              sessionID: UInt32, body: ResponseBody) throws -> Response {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let hostEphemeral = Array(ephemeral.publicKey.rawRepresentation)
        guard let clientPublic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: accepted.clientEphemeral),
              let shared = try? ephemeral.sharedSecretFromKeyAgreement(with: clientPublic)
        else { throw HandshakeError.authenticationFailed }

        let t1 = KeySchedule.transcript1(transcript0: accepted.transcript0, hostEphemeral: hostEphemeral,
                                         sessionID: sessionID)
        let established = KeySchedule.established(psk: psk, shared: shared, transcript1: t1)

        var body = body
        body.resetToken = KeySchedule.resetToken(hostSecret: hostSecret, sessionID: sessionID)

        let prefix = ResponsePrefix(sessionID: sessionID, hostEphemeral: hostEphemeral)
        var w = ByteWriter(out)
        try prefix.encode(into: &w)

        let bodyScratch = UnsafeMutableRawBufferPointer.allocate(byteCount: out.count, alignment: 16)
        defer { bodyScratch.deallocate() }
        var bw = ByteWriter(bodyScratch)
        try body.encode(into: &bw)
        guard let sealedLength = PacketProtection.sealHandshake(
            body: UnsafeRawBufferPointer(rebasing: bodyScratch[..<bw.written]),
            prefix: UnsafeRawBufferPointer(rebasing: out[..<w.written]),
            keys: established.response,
            into: UnsafeMutableRawBufferPointer(rebasing: out[w.written...]))
        else { throw HandshakeError.malformed }

        return Response(length: w.written + sealedLength,
                        keys: TrafficKeys(clientToHost: established.clientToHost,
                                          hostToClient: established.hostToClient),
                        resetToken: body.resetToken)
    }

    /// SESSION_UNKNOWN for a session this host has no state for. 21 bytes, so it
    /// is always smaller than the packet that triggered it.
    public func writeSessionUnknown(into out: UnsafeMutableRawBufferPointer, sessionID: UInt32) throws -> Int {
        let token = KeySchedule.resetToken(hostSecret: hostSecret, sessionID: sessionID)
        var w = ByteWriter(out)
        try SessionUnknown(sessionID: sessionID, token: token).encode(into: &w)
        return w.written
    }

    public func verify(sessionUnknown: SessionUnknown) -> Bool {
        KeySchedule.verifyResetToken(sessionUnknown.token, hostSecret: hostSecret,
                                     sessionID: sessionUnknown.sessionID)
    }

    public func resetToken(for sessionID: UInt32) -> [UInt8] {
        KeySchedule.resetToken(hostSecret: hostSecret, sessionID: sessionID)
    }
}
