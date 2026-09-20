import LightrayCore
import Testing

/// Round trips for every v0 codec. `Docs/protocol-v0.md` is normative and these
/// are what keep it honest.
@Suite("Wire")
struct WireTests {
    /// Encodes with `body` and hands back the bytes.
    static func encode(_ capacity: Int = 2048, _ body: (inout ByteWriter) throws -> Void) throws -> [UInt8] {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity, alignment: 64)
        defer { buffer.deallocate() }
        var w = ByteWriter(buffer)
        try body(&w)
        return Array(w.contents)
    }

    /// Decodes with `body` over a borrowed span.
    static func decode<T>(_ bytes: [UInt8], _ body: (inout ByteReader) throws -> T) throws -> T {
        try bytes.withUnsafeBytes { raw in
            let span = RawSpan(_unsafeBytes: raw)
            var r = ByteReader(span)
            return try body(&r)
        }
    }

    @Test func packetHeaderRoundTrip() throws {
        let header = PacketHeader(sessionID: 0xDEAD_BEEF, transportSeq: 0x0102_0304,
                                  sendTimeMicros: 0xAABB_CCDD)
        let bytes = try Self.encode { try header.encode(into: &$0) }
        #expect(bytes.count == 16, "the header is exactly 16 bytes")
        #expect(bytes[0] & 0x80 == 0, "bit 7 clear marks the short form")
        #expect(Array(bytes[4..<8]) == [0xDE, 0xAD, 0xBE, 0xEF], "big-endian session id")
        let back = try Self.decode(bytes) { try PacketHeader.decode(&$0) }
        #expect(back == header)

        // Peeking works without keys, which is how the host routes a packet to a
        // session before it can authenticate it.
        bytes.withUnsafeBytes { raw in
            #expect(PacketHeader.peekSessionID(raw) == 0xDEAD_BEEF)
            #expect(PacketHeader.peekTransportSeq(raw) == 0x0102_0304)
        }
    }

    @Test func aHandshakeFirstByteIsNotAShortHeader() throws {
        #expect(PacketHeader.isHandshake(firstByte: 0x80))
        #expect(PacketHeader.isHandshake(firstByte: 0x81))
        #expect(PacketHeader.isHandshake(firstByte: 0x82))
        #expect(!PacketHeader.isHandshake(firstByte: 0x00))
        // A header decode must refuse a handshake byte rather than misread it.
        #expect(throws: WireError.malformed) {
            try Self.decode([0x80, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3]) {
                try PacketHeader.decode(&$0)
            }
        }
    }

    @Test func payloadBudgetAtTheDefaultDatagramSize() {
        // 16 header + 16 tag + 3 chunk + 13 fragment + 3 FEC TLV = 51 bytes,
        // leaving 1149 of 1200 for payload: 95.75%.
        #expect(Wire.maxFragmentPayload(maxDatagramSize: 1200) == 1149)
        #expect(Wire.maxChunkSpace(maxDatagramSize: 1200) == 1168)
        let overhead = 1200 - Wire.maxFragmentPayload(maxDatagramSize: 1200)
        #expect(overhead == 51)
        #expect(Wire.minProtectedSize == 32)
        // SESSION_UNKNOWN must always be smaller than what triggers it.
        #expect(SessionUnknown.size < Wire.minProtectedSize)
    }

    @Test func fragmentRoundTripCarriesStride() throws {
        let header = FragmentHeader(stream: 3, flags: [.keyframe, .frameStart], frameID: 77,
                                    index: 5, count: 9, stride: 1149)
        let payload = [UInt8](repeating: 0x5A, count: 40)
        let bytes = try Self.encode {
            let site = try $0.beginChunk(.mediaFragment)
            try header.encode(into: &$0)
            try $0.put(payload)
            $0.endChunk(site)
        }
        // chunk header + fragment header + FEC TLV + payload
        #expect(bytes.count == 3 + 13 + 3 + 40)

        let result = try Self.decode(bytes) { r -> (FragmentHeader, Int, UInt8) in
            guard let chunk = try r.nextChunk() else { throw WireError.truncated }
            #expect(chunk.type == ChunkType.mediaFragment.rawValue)
            var body = ByteReader(chunk.body)
            let fragment = try body.fragment()
            return (fragment.header, fragment.payload.byteCount,
                    fragment.payload.unsafeLoad(fromUncheckedByteOffset: 0, as: UInt8.self))
        }
        #expect(result.0 == header)
        #expect(result.1 == 40)
        #expect(result.2 == 0x5A)
        // Stride on the wire is what lets a receiver place any fragment at once,
        // including a last fragment that arrives first.
        #expect(result.0.payloadOffset == 5 * 1149)
    }

    @Test func aFragmentWithAnIndexPastItsCountIsMalformed() throws {
        var bytes = try Self.encode {
            try FragmentHeader(stream: 1, flags: [], frameID: 1, index: 0, count: 4, stride: 100)
                .encode(into: &$0)
        }
        bytes[2] = 0; bytes[3] = 0; bytes[4] = 0; bytes[5] = 1   // frame_id = 1
        bytes[6] = 0; bytes[7] = 9                                // index = 9 with count 4
        #expect(throws: WireError.malformed) {
            try Self.decode(bytes) { try $0.fragment() }
        }
    }

    @Test func unknownChunksAndTLVsAreSkipped() throws {
        // A chunk type v0 does not know, followed by one it does. The unknown one
        // must be skipped, not fatal: that is what lets a later version add
        // chunks without a version bump.
        let bytes = try Self.encode {
            try $0.put(UInt8(0x7E))            // unknown type
            try $0.put(UInt16(4))
            try $0.put(UInt32(0xFFFF_FFFF))
            let site = try $0.beginChunk(.close)
            try $0.put(CloseCode.timeout.rawValue)
            $0.endChunk(site)
        }
        let code = try Self.decode(bytes) { r -> UInt16? in
            var found: UInt16?
            while let chunk = try r.nextChunk() {
                guard chunk.knownType == .close else { continue }
                var body = ByteReader(chunk.body)
                found = try body.u16()
            }
            return found
        }
        #expect(code == CloseCode.timeout.rawValue)
    }

    @Test func feedbackReportsArrivalsAndGaps() throws {
        // Packets 100...109, with 102 and 105 missing.
        let arrivals: [UInt32: UInt32] = [
            100: 1_000_000, 101: 1_000_100, 103: 1_000_300,
            104: 1_000_400, 106: 1_000_600, 107: 1_000_700,
            108: 1_000_800, 109: 1_000_900,
        ]
        let bytes = try Self.encode {
            try Feedback.encode(into: &$0, baseSeq: 100, count: 10) { arrivals[$0] }
        }
        var seen: [(UInt32, UInt32?)] = []
        let header = try Self.decode(bytes) { r in
            try Feedback.decode(&r) { seq, arrival in seen.append((seq, arrival)) }
        }
        #expect(header.baseSeq == 100)
        #expect(header.count == 10)
        #expect(seen.count == 10)
        #expect(seen.filter { $0.1 == nil }.map(\.0) == [102, 105], "the gaps are reported as gaps")
        // Arrival times survive the 4 µs delta encoding.
        for (seq, arrival) in seen {
            guard let arrival, let expected = arrivals[seq] else { continue }
            let error = Int64(arrival) - Int64(expected)
            #expect(abs(error) <= 4, "seq \(seq) off by \(error) µs")
        }
    }

    @Test func feedbackCapacityMatchesTheMeasuredLimit() {
        // One 1200-byte datagram covers at most 543 reported packets.
        let capacity = FeedbackHeader.capacity(bytesAvailable: Wire.maxChunkSpace(maxDatagramSize: 1200)
                                                 - Wire.chunkHeaderSize)
        #expect(capacity >= 540 && capacity <= 560, "capacity \(capacity)")
        // An i16 delta in 4 µs units spans about ±131 ms.
        #expect(FeedbackHeader.maxDelta == 131_068)
    }

    @Test func nackEntriesRoundTripIncludingWholeFrames() throws {
        let entries = [
            NackEntry(frameID: 10, first: 0, count: 3),
            NackEntry(frameID: 11, first: 7, count: 1),
            NackEntry(frameID: 12, first: 0, count: 0),   // the whole frame
        ]
        let bytes = try Self.encode { try Nack.encode(into: &$0, stream: 2, entries: entries) }
        #expect(bytes.count == 1 + 3 * NackEntry.entrySize)
        var decoded: [NackEntry] = []
        let stream = try Self.decode(bytes) { try Nack.decode(&$0) { decoded.append($0) } }
        #expect(stream == 2)
        #expect(decoded == entries)
        #expect(decoded[2].isWholeFrame, "count 0 means the fragment count is unknown")
    }

    @Test func frameAckAndRefreshRequestRoundTrip() throws {
        let acks = [
            FrameAckEntry(stream: 1, frameID: 500, status: .decoded),
            FrameAckEntry(stream: 1, frameID: 501, status: .received),
        ]
        let ackBytes = try Self.encode { try FrameAck.encode(into: &$0, entries: acks) }
        var decodedAcks: [FrameAckEntry] = []
        try Self.decode(ackBytes) { try FrameAck.decode(&$0) { decodedAcks.append($0) } }
        #expect(decodedAcks == acks)

        let request = RefreshRequest(stream: 1, reason: .loss, preferred: .ltr,
                                     lastGoodFrame: 480, lostFrame: 491, reqID: 7)
        let bytes = try Self.encode { try request.encode(into: &$0) }
        #expect(bytes.count == 15)
        #expect(try Self.decode(bytes) { try RefreshRequest.decode(&$0) } == request)
    }

    @Test func frameHeaderCarriesCodecConfigOnAnIDR() throws {
        let config = [UInt8](repeating: 0xAB, count: 81)     // HEVC VPS+SPS+PPS
        var header = FrameHeader(frameType: .idr, refKind: .none, flags: [.ltrMark],
                                 configGeneration: 3, captureTimeMicros: 123_456)
        header.codecConfigLength = config.count
        let frameBytes: [UInt8] = [9, 9, 9, 9, 9]
        let bytes = try Self.encode { (w: inout ByteWriter) in
            try config.withUnsafeBytes { raw in try header.encode(into: &w, codecConfig: raw) }
            try w.put(frameBytes)
        }
        #expect(bytes.count == header.encodedSize + frameBytes.count)

        let layout = try bytes.withUnsafeBytes { try FrameHeader.parse($0) }
        #expect(layout.header.frameType == .idr)
        #expect(layout.header.ltrMarked)
        #expect(layout.header.configGeneration == 3)
        #expect(layout.header.captureTimeMicros == 123_456)
        #expect(layout.codecConfig.map { $0.count } == 81, "every IDR carries its own parameter sets")
        #expect(Array(bytes[layout.payload]) == frameBytes)
        #expect(Array(bytes[layout.codecConfig!]) == config)
    }

    @Test func aFrameHeaderReferencingAnLTRCarriesTheID() throws {
        let header = FrameHeader(frameType: .predicted, refKind: .ltr, configGeneration: 1,
                                 captureTimeMicros: 5, refFrameID: 4242)
        let bytes = try Self.encode { try header.encode(into: &$0, codecConfig: nil) }
        let layout = try bytes.withUnsafeBytes { try FrameHeader.parse($0) }
        #expect(layout.header.refFrameID == 4242)

        // ltrAny carries no id: the encoder chose and does not report its choice.
        let any = FrameHeader(frameType: .predicted, refKind: .ltrAny, configGeneration: 1,
                              captureTimeMicros: 5)
        let anyBytes = try Self.encode { try any.encode(into: &$0, codecConfig: nil) }
        #expect(anyBytes.count == bytes.count - 4)
        let anyLayout = try anyBytes.withUnsafeBytes { try FrameHeader.parse($0) }
        #expect(anyLayout.header.refKind == .ltrAny)
        #expect(anyLayout.header.refFrameID == nil)
    }

    @Test func controlMessagesRoundTripAndApply() throws {
        var body = ControlBody(message: .reconfigure, reqID: 9, scopeStream: 1)
        body.bitrate = 12_000_000
        body.resolution = (2560, 1440)
        body.framerate = 120
        body.hdr = true
        let bytes = try Self.encode { try body.encode(into: &$0) }
        let back = try Self.decode(bytes) { try ControlBody.decode(&$0) }
        #expect(back == body)

        var config = SessionConfig()
        let generationBefore = config.generation
        let rejected = back.apply(to: &config)
        #expect(rejected == 0)
        #expect(config.bitrate == 12_000_000)
        #expect(config.width == 2560 && config.height == 1440)
        #expect(config.framerate == 120)
        #expect(config.hdr)
        #expect(config.generation == generationBefore + 1, "config_generation bumps on a change")

        // Re-applying the same values changes nothing, so the generation holds.
        let again = back.apply(to: &config)
        #expect(again == 0)
        #expect(config.generation == generationBefore + 1)
    }

    @Test func handshakePrefixesRoundTrip() throws {
        let ephemeral = (0..<32).map { UInt8(truncatingIfNeeded: $0) }
        let initPrefix = InitPrefix(pairingID: 0x1122_3344_5566_7788, clientEphemeral: ephemeral)
        let initBytes = try Self.encode { try initPrefix.encode(into: &$0) }
        #expect(initBytes.count == InitPrefix.size)
        #expect(initBytes[0] == HandshakeType.initPacket.rawValue)
        #expect(try Self.decode(initBytes) { try InitPrefix.decode(&$0) } == initPrefix)

        let response = ResponsePrefix(sessionID: 0xABCD_1234, hostEphemeral: ephemeral)
        let responseBytes = try Self.encode { try response.encode(into: &$0) }
        #expect(responseBytes.count == ResponsePrefix.size)
        #expect(try Self.decode(responseBytes) { try ResponsePrefix.decode(&$0) } == response)

        let unknown = SessionUnknown(sessionID: 7, token: [UInt8](repeating: 0xEE, count: 16))
        let unknownBytes = try Self.encode { try unknown.encode(into: &$0) }
        #expect(unknownBytes.count == SessionUnknown.size)
        #expect(try Self.decode(unknownBytes) { try SessionUnknown.decode(&$0) } == unknown)
    }

    @Test func aVersionMismatchIsReportedBeforeAnyCrypto() throws {
        var bytes = try Self.encode {
            try InitPrefix(pairingID: 1, clientEphemeral: [UInt8](repeating: 0, count: 32))
                .encode(into: &$0)
        }
        bytes[1] = 99   // a version this build does not implement
        #expect(throws: WireError.unsupportedVersion(99)) {
            try Self.decode(bytes) { try InitPrefix.decode(&$0) }
        }
    }

    @Test func handshakeBodiesRoundTrip() throws {
        var body = InitBody()
        body.capabilities = [.ltr, .fec]
        body.streams = [
            StreamDescriptor(id: 1, kind: .video, direction: .hostToClient, streamClass: .media),
            StreamDescriptor(id: 2, kind: .mic, direction: .clientToHost, streamClass: .realtime),
        ]
        body.clientTimestamp = 0xDEAD_BEEF_CAFE
        body.resumeSessionID = 4242
        let bytes = try Self.encode { try body.encode(into: &$0) }
        let back = try Self.decode(bytes) { try InitBody.decode(&$0) }
        #expect(back.capabilities == body.capabilities)
        #expect(back.streams == body.streams)
        #expect(back.clientTimestamp == body.clientTimestamp)
        #expect(back.resumeSessionID == 4242)

        var response = ResponseBody()
        response.acceptedCapabilities = [.ltr]
        response.streams = body.streams
        response.pipelineIdleAfterMillis = 60_000
        response.graceWindowMillis = 1_800_000
        response.resetToken = [UInt8](repeating: 0x11, count: 16)
        response.adoptedResume = true
        let responseBytes = try Self.encode { try response.encode(into: &$0) }
        let responseBack = try Self.decode(responseBytes) { try ResponseBody.decode(&$0) }
        #expect(responseBack.acceptedCapabilities == [.ltr])
        #expect(responseBack.pipelineIdleAfterMillis == 60_000)
        #expect(responseBack.graceWindowMillis == 1_800_000)
        #expect(responseBack.resetToken == response.resetToken)
        #expect(responseBack.adoptedResume)
    }
}
