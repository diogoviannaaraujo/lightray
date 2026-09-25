/// The worked example that `docs/handshake.md` and `docs/packets.md` follow from start to end.
/// Building it runs both sides of the handshake and traps unless they agree.
public struct Example: Sendable {
    // Inputs. Where version 0's example had the same input, the value is carried over.
    public static let psk = Bytes(0...31)
    public static let pairingID: UInt64 = 0x1122_3344_5566_7788
    public static let clientEphemeralPrivate = Bytes(repeating: 0x11, count: 32)
    public static let hostEphemeralPrivate = Bytes(repeating: 0x22, count: 32)
    public static let maxDatagramSize = 256
    public static let timestamp: UInt64 = 1_700_000_000
    public static let sessionID: UInt32 = 0xABCD_1234
    public static let hostSecret = Bytes(repeating: 0x33, count: 32)
    public static let streamTable = [
        StreamEntry(
            id: 1, kind: StreamEntry.Kind.video, direction: StreamEntry.Direction.hostToClient,
            streamClass: StreamEntry.Class.media),
        StreamEntry(
            id: 2, kind: StreamEntry.Kind.audio, direction: StreamEntry.Direction.hostToClient,
            streamClass: StreamEntry.Class.realtime),
        StreamEntry(
            id: 3, kind: StreamEntry.Kind.mic, direction: StreamEntry.Direction.clientToHost,
            streamClass: StreamEntry.Class.realtime),
        StreamEntry(
            id: 4, kind: StreamEntry.Kind.input, direction: StreamEntry.Direction.clientToHost,
            streamClass: StreamEntry.Class.reliable),
    ]
    /// The protected datagram: host to client, packet number 7, a `CLOSE` with `GOING_AWAY`.
    public static let datagramPacketNumber: UInt64 = 7
    public static let datagramSendTime: UInt32 = 2_500_000

    public let initParams: Bytes
    public let initPrologue: Bytes
    public let initPayload: Bytes
    public let initDatagram: Bytes
    public let initTrace: [TraceLine]
    public let resetToken: Bytes
    public let responseParams: Bytes
    public let responsePayload: Bytes
    public let responseDatagram: Bytes
    public let responseTrace: [TraceLine]
    public let handshakeHash: Bytes
    public let clientToHostKey: Bytes
    public let hostToClientKey: Bytes
    public let sessionUnknown: Bytes
    public let datagramHeader: ProtectedHeader
    public let datagramChunks: Bytes
    public let datagram: Bytes

    public init() {
        let table = Self.streamTable.flatMap(\.bytes)
        initParams =
            tlv(Handshake.Param.timestamp, be64(Self.timestamp))
            + tlv(Handshake.Param.streamTable, table)
            + tlv(Handshake.Param.maxDatagramSize, be16(UInt16(Self.maxDatagramSize)))
        initPrologue = Handshake.prologue(initHeader: Handshake.initHeader(pairingID: Self.pairingID))
        initPayload = Handshake.initPayload(params: initParams, maxDatagramSize: Self.maxDatagramSize)

        let built = Handshake.buildInit(
            psk: Self.psk, pairingID: Self.pairingID, ephemeralPrivate: Self.clientEphemeralPrivate,
            params: initParams, maxDatagramSize: Self.maxDatagramSize)
        initDatagram = built.datagram
        var initiator = built.initiator
        initTrace = initiator.trace

        // The host opens the INIT with the pairing's PSK and answers it.
        guard
            let opened = Handshake.readInit(
                initDatagram, psk: Self.psk, ephemeralPrivate: Self.hostEphemeralPrivate)
        else { preconditionFailure("the host could not open the example INIT") }
        precondition(opened.payload == initPayload)
        var responder = opened.responder
        let traceStart = responder.trace.count
        resetToken = Handshake.resetToken(hostSecret: Self.hostSecret, sessionID: Self.sessionID)
        responseParams =
            tlv(Handshake.Param.streamTable, table)
            + tlv(Handshake.Param.maxDatagramSize, be16(UInt16(Self.maxDatagramSize)))
        responsePayload = Handshake.responsePayload(
            sessionID: Self.sessionID, resetToken: resetToken, params: responseParams)
        responseDatagram = Handshake.buildResponse(responder: &responder, payload: responsePayload)
        responseTrace = Array(responder.trace[traceStart...])
        precondition(responseDatagram.count <= initDatagram.count)

        // The client opens the RESPONSE, and both sides must now hold the same keys.
        precondition(Handshake.readResponse(responseDatagram, initiator: &initiator) == responsePayload)
        precondition(initiator.handshakeHash == responder.handshakeHash)
        let (clientSend, clientReceive) = initiator.split()
        let (hostReceive, hostSend) = responder.split()
        precondition(clientSend.key == hostReceive.key && clientReceive.key == hostSend.key)
        handshakeHash = initiator.handshakeHash
        clientToHostKey = clientSend.key!
        hostToClientKey = hostSend.key!

        sessionUnknown = Handshake.sessionUnknown(sessionID: Self.sessionID, token: resetToken)

        datagramHeader = ProtectedHeader(
            sessionID: Self.sessionID, transportSeq: UInt32(Self.datagramPacketNumber),
            sendTimeMicros: Self.datagramSendTime)
        datagramChunks = Packet.close(Packet.CloseCode.goingAway)
        datagram = Packet.seal(
            header: datagramHeader, packetNumber: Self.datagramPacketNumber, key: hostToClientKey,
            chunks: datagramChunks)
        precondition(
            Packet.open(datagram, key: hostToClientKey, expected: Self.datagramPacketNumber)?.chunks
                == datagramChunks)
    }

    /// Packet-number reconstruction cases: ordinary reordering, both directions across the
    /// 2³² boundary, and both sides of the half-window edge.
    public static let packetNumberCases: [(expected: UInt64, transportSeq: UInt32)] = [
        (0, 0x0000_0000),
        (0x8, 0x0000_0007),
        (0xffff_fffe, 0x0000_0003),
        (0x1_0000_0002, 0xffff_fffd),
        (0x1_0000_0000, 0x8000_0000),
        (0x1_0000_0000, 0x8000_0001),
    ]
}

public enum Catalog {
    /// Every block the documents print, by the name its `<!-- vector: name -->` marker uses.
    public static func blocks(_ example: Example = Example()) -> [(name: String, text: String)] {
        [
            ("handshake.init.prologue", hexLines(example.initPrologue)),
            ("handshake.init.params", hexLines(example.initParams)),
            ("handshake.init.trace", renderTrace(example.initTrace)),
            ("handshake.init.datagram", hexLines(example.initDatagram)),
            ("handshake.response.payload", hexLines(example.responsePayload)),
            ("handshake.response.trace", renderTrace(example.responseTrace)),
            ("handshake.response.datagram", hexLines(example.responseDatagram)),
            (
                "handshake.keys",
                renderLabelled([
                    ("client-to-host key", example.clientToHostKey),
                    ("host-to-client key", example.hostToClientKey),
                ])
            ),
            ("handshake.session-unknown", hexLines(example.sessionUnknown)),
            ("packets.pn-reconstruction", packetNumberTable()),
            ("packets.close", Packet.close(Packet.CloseCode.appRequest).hex),
            ("packets.datagram.header", example.datagramHeader.bytes.hex),
            ("packets.datagram.nonce", Noise.nonceBytes(Example.datagramPacketNumber).hex),
            ("packets.datagram.chunks", example.datagramChunks.hex),
            ("packets.datagram", hexLines(example.datagram)),
        ]
    }

    static func packetNumberTable() -> String {
        let rows = Example.packetNumberCases.map { expected, transportSeq in
            (
                hexNumber(expected, digits: 16), hexNumber(UInt64(transportSeq), digits: 8),
                hexNumber(Packet.reconstruct(expected: expected, transportSeq: transportSeq), digits: 16)
            )
        }
        let header = ("expected", "transport_seq", "packet number")
        let widths = (
            rows.map(\.0.count).max()!, max(header.1.count, rows.map(\.1.count).max()!)
        )
        func line(_ a: String, _ b: String, _ c: String) -> String {
            a + String(repeating: " ", count: widths.0 - a.count + 2)
                + b + String(repeating: " ", count: widths.1 - b.count + 2) + c
        }
        return ([line(header.0, header.1, header.2)] + rows.map { line($0.0, $0.1, $0.2) })
            .joined(separator: "\n")
    }

    /// `vectors.json`: the inputs and outputs of the worked examples, for implementations
    /// in any language.
    public static func json(_ example: Example = Example()) -> JSONValue {
        .object([
            ("protocol", .string("Lightray")),
            ("version", .int(1)),
            (
                "about",
                .string(
                    "Generated by tools/vectors. Byte strings are hex. docs/handshake.md and docs/packets.md explain every value."
                )
            ),
            (
                "handshake",
                .object([
                    (
                        "inputs",
                        .object([
                            ("noise_protocol", .string(Noise.protocolName)),
                            ("psk", .hex(Example.psk)),
                            ("pairing_id", .hex(be64(Example.pairingID))),
                            ("client_ephemeral_private", .hex(Example.clientEphemeralPrivate)),
                            ("host_ephemeral_private", .hex(Example.hostEphemeralPrivate)),
                            ("max_datagram_size", .int(UInt64(Example.maxDatagramSize))),
                            ("init_params", .hex(example.initParams)),
                            ("session_id", .int(UInt64(Example.sessionID))),
                            ("host_secret", .hex(Example.hostSecret)),
                            ("response_params", .hex(example.responseParams)),
                        ])
                    ),
                    (
                        "outputs",
                        .object([
                            ("prologue", .hex(example.initPrologue)),
                            ("client_ephemeral_public", .hex(Noise.publicKey(Example.clientEphemeralPrivate))),
                            ("init_payload", .hex(example.initPayload)),
                            ("init", .hex(example.initDatagram)),
                            ("host_ephemeral_public", .hex(Noise.publicKey(Example.hostEphemeralPrivate))),
                            ("reset_token", .hex(example.resetToken)),
                            ("response_payload", .hex(example.responsePayload)),
                            ("response", .hex(example.responseDatagram)),
                            ("handshake_hash", .hex(example.handshakeHash)),
                            ("client_to_host_key", .hex(example.clientToHostKey)),
                            ("host_to_client_key", .hex(example.hostToClientKey)),
                            ("session_unknown", .hex(example.sessionUnknown)),
                        ])
                    ),
                ])
            ),
            (
                "packet_numbers",
                .array(
                    Example.packetNumberCases.map { expected, transportSeq in
                        .object([
                            ("expected", .int(expected)),
                            ("transport_seq", .int(UInt64(transportSeq))),
                            ("packet_number", .int(Packet.reconstruct(expected: expected, transportSeq: transportSeq))),
                        ])
                    })
            ),
            (
                "protected_datagram",
                .object([
                    (
                        "inputs",
                        .object([
                            ("key", .hex(example.hostToClientKey)),
                            ("packet_number", .int(Example.datagramPacketNumber)),
                            ("session_id", .int(UInt64(Example.sessionID))),
                            ("send_time_us", .int(UInt64(Example.datagramSendTime))),
                            ("chunks", .hex(example.datagramChunks)),
                        ])
                    ),
                    (
                        "outputs",
                        .object([
                            ("header", .hex(example.datagramHeader.bytes)),
                            ("nonce", .hex(Noise.nonceBytes(Example.datagramPacketNumber))),
                            ("datagram", .hex(example.datagram)),
                        ])
                    ),
                ])
            ),
        ])
    }
}
