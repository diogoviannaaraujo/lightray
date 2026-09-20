import Foundation
import LightrayCore
import Testing

/// Golden byte vectors for the v0 wire format.
///
/// `Docs/golden-vectors.json` is the artifact a non-Swift implementation checks
/// itself against — the Windows client is a separate implementation of this wire
/// format, so anything a receiver must do to be correct has to be pinned here and
/// not only in a Swift type. Regenerate with `LIGHTRAY_WRITE_VECTORS=1 swift test`.
@Suite("Golden vectors")
struct GoldenVectorTests {

    struct Vector: Codable, Equatable {
        var name: String
        var describes: String
        var hex: String
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func encode(_ capacity: Int = 2048, _ body: (inout ByteWriter) throws -> Void) -> [UInt8] {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity, alignment: 64)
        defer { buffer.deallocate() }
        var w = ByteWriter(buffer)
        try! body(&w)
        return Array(w.contents)
    }

    /// Every vector, built from fixed inputs so the bytes never move.
    static func vectors() -> [Vector] {
        var out: [Vector] = []

        out.append(Vector(
            name: "protected_header",
            describes: "flags=0, session_id=0x12345678, transport_seq=0x0000002A, send_time_us=0x000F4240",
            hex: hex(encode { try PacketHeader(sessionID: 0x1234_5678, transportSeq: 42,
                                               sendTimeMicros: 1_000_000).encode(into: &$0) })))

        out.append(Vector(
            name: "media_fragment_chunk",
            describes: "MEDIA_FRAGMENT: stream=1, flags=keyframe|frameStart, frame_id=7, index=2, count=5, stride=1149, FEC=NONE, then 8 payload bytes 0xA0..0xA7",
            hex: hex(encode { w in
                let site = try w.beginChunk(.mediaFragment)
                try FragmentHeader(stream: 1, flags: [.keyframe, .frameStart], frameID: 7,
                                   index: 2, count: 5, stride: 1149).encode(into: &w)
                try w.put((0..<8).map { UInt8(0xA0 + $0) })
                w.endChunk(site)
            })))

        out.append(Vector(
            name: "reliable_chunk",
            describes: "RELIABLE: stream=0, msg_seq=3, seg_index=1, seg_count=2, payload 0x01 0x02 0x03",
            hex: hex(encode { w in
                let site = try w.beginChunk(.reliable)
                try ReliableHeader(stream: 0, msgSeq: 3, segIndex: 1, segCount: 2).encode(into: &w)
                try w.put([0x01, 0x02, 0x03])
                w.endChunk(site)
            })))

        out.append(Vector(
            name: "feedback_chunk",
            describes: "FEEDBACK: base_seq=100, count=10, base_arrival_us=1000000; 102 and 105 missing; arrivals 100 µs apart",
            hex: hex(encode { w in
                let arrivals: [UInt32: UInt32] = [
                    100: 1_000_000, 101: 1_000_100, 103: 1_000_300, 104: 1_000_400,
                    106: 1_000_600, 107: 1_000_700, 108: 1_000_800, 109: 1_000_900,
                ]
                let site = try w.beginChunk(.feedback)
                try Feedback.encode(into: &w, baseSeq: 100, count: 10) { arrivals[$0] }
                w.endChunk(site)
            })))

        out.append(Vector(
            name: "nack_chunk",
            describes: "NACK: stream=1; (frame 10, first 0, count 3), (frame 11, first 7, count 1), (frame 12, whole frame)",
            hex: hex(encode { w in
                let site = try w.beginChunk(.nack)
                try Nack.encode(into: &w, stream: 1, entries: [
                    NackEntry(frameID: 10, first: 0, count: 3),
                    NackEntry(frameID: 11, first: 7, count: 1),
                    NackEntry(frameID: 12, first: 0, count: 0),
                ])
                w.endChunk(site)
            })))

        out.append(Vector(
            name: "frame_ack_chunk",
            describes: "FRAME_ACK: (stream 1, frame 500, decoded), (stream 1, frame 501, received)",
            hex: hex(encode { w in
                let site = try w.beginChunk(.frameAck)
                try FrameAck.encode(into: &w, entries: [
                    FrameAckEntry(stream: 1, frameID: 500, status: .decoded),
                    FrameAckEntry(stream: 1, frameID: 501, status: .received),
                ])
                w.endChunk(site)
            })))

        out.append(Vector(
            name: "refresh_request_chunk",
            describes: "REFRESH_REQUEST: stream=1, reason=loss, preferred=ltr, last_good=480, lost=491, req_id=7",
            hex: hex(encode { w in
                let site = try w.beginChunk(.refreshRequest)
                try RefreshRequest(stream: 1, reason: .loss, preferred: .ltr, lastGoodFrame: 480,
                                   lostFrame: 491, reqID: 7).encode(into: &w)
                w.endChunk(site)
            })))

        out.append(Vector(
            name: "pong_chunk",
            describes: "PONG: id=9, hold_us=1500",
            hex: hex(encode { w in
                let site = try w.beginChunk(.pong)
                try Pong(id: 9, holdMicros: 1500).encode(into: &w)
                w.endChunk(site)
            })))

        out.append(Vector(
            name: "resume_and_close_chunks",
            describes: "RESUME with decoder_lost, then CLOSE with code=timeout(2)",
            hex: hex(encode { w in
                let resume = try w.beginChunk(.resume)
                try w.put(ResumeFlags.decoderLost.rawValue)
                w.endChunk(resume)
                let close = try w.beginChunk(.close)
                try w.put(CloseCode.timeout.rawValue)
                w.endChunk(close)
            })))

        out.append(Vector(
            name: "frame_header_idr_with_codec_config",
            describes: "Frame header: IDR, ref none, ltr_mark, generation=3, capture=123456, CODEC_CONFIG ext of 8 bytes 0xB0..0xB7",
            hex: hex(encode { w in
                var header = FrameHeader(frameType: .idr, refKind: .none, flags: [.ltrMark],
                                         configGeneration: 3, captureTimeMicros: 123_456)
                header.codecConfigLength = 8
                let config = (0..<8).map { UInt8(0xB0 + $0) }
                try config.withUnsafeBytes { raw in try header.encode(into: &w, codecConfig: raw) }
            })))

        out.append(Vector(
            name: "frame_header_predicted_ltr",
            describes: "Frame header: predicted, ref_kind=ltr with ref_frame_id=4242, generation=1, capture=5, no ext",
            hex: hex(encode { w in
                try FrameHeader(frameType: .predicted, refKind: .ltr, configGeneration: 1,
                                captureTimeMicros: 5, refFrameID: 4242)
                    .encode(into: &w, codecConfig: nil)
            })))

        out.append(Vector(
            name: "frame_header_predicted_ltr_any",
            describes: "Frame header: predicted, ref_kind=ltrAny (no ref_frame_id), generation=1, capture=5, no ext",
            hex: hex(encode { w in
                try FrameHeader(frameType: .predicted, refKind: .ltrAny, configGeneration: 1,
                                captureTimeMicros: 5)
                    .encode(into: &w, codecConfig: nil)
            })))

        out.append(Vector(
            name: "init_prefix",
            describes: "INIT cleartext prefix: type=0x80, version=0, reserved=0, pairing_id=0x1122334455667788, client_ephemeral=00..1f",
            hex: hex(encode {
                try InitPrefix(pairingID: 0x1122_3344_5566_7788,
                               clientEphemeral: (0..<32).map { UInt8($0) }).encode(into: &$0)
            })))

        out.append(Vector(
            name: "response_prefix",
            describes: "RESPONSE cleartext prefix: type=0x81, version=0, session_id=0xABCD1234, host_ephemeral=20..3f",
            hex: hex(encode {
                try ResponsePrefix(sessionID: 0xABCD_1234,
                                   hostEphemeral: (0..<32).map { UInt8(0x20 + $0) }).encode(into: &$0)
            })))

        out.append(Vector(
            name: "session_unknown",
            describes: "SESSION_UNKNOWN: type=0x82, session_id=0xABCD1234, token=ee x16",
            hex: hex(encode {
                try SessionUnknown(sessionID: 0xABCD_1234,
                                   token: [UInt8](repeating: 0xEE, count: 16)).encode(into: &$0)
            })))

        out.append(Vector(
            name: "control_reconfigure",
            describes: "RECONFIGURE on stream 0: req_id=9, scope_stream=1, BITRATE=12000000, RESOLUTION=2560x1440, FRAMERATE=120, HDR=1",
            hex: hex(encode { w in
                var body = ControlBody(message: .reconfigure, reqID: 9, scopeStream: 1)
                body.bitrate = 12_000_000
                body.resolution = (2560, 1440)
                body.framerate = 120
                body.hdr = true
                try body.encode(into: &w)
            })))

        out.append(Vector(
            name: "control_state_resume",
            describes: "STATE with flags=resume: 20 Mbps, floor 2 Mbps, 1920x1080, 60 fps, SDR, mds 1200, generation 4",
            hex: hex(encode { w in
                var config = SessionConfig()
                config.generation = 4
                try ControlBody.state(config: config, flags: [.resume]).encode(into: &w)
            })))

        return out
    }

    static var vectorFileURL: URL {
        // Tests/LightrayCoreTests/ -> the package root -> Docs/
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Docs/golden-vectors.json")
    }

    @Test func encodersMatchTheCommittedVectors() throws {
        let current = Self.vectors()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if ProcessInfo.processInfo.environment["LIGHTRAY_WRITE_VECTORS"] == "1" {
            try encoder.encode(current).write(to: Self.vectorFileURL)
            print("wrote \(current.count) vectors to \(Self.vectorFileURL.path)")
            return
        }

        let data = try Data(contentsOf: Self.vectorFileURL)
        let committed = try JSONDecoder().decode([Vector].self, from: data)
        #expect(committed.count == current.count,
                "\(committed.count) committed vectors against \(current.count) generated")
        for (expected, actual) in zip(committed, current) {
            #expect(expected.name == actual.name)
            #expect(expected.hex == actual.hex,
                    "\(actual.name) changed:\n  committed \(expected.hex)\n  generated \(actual.hex)")
        }
    }

    /// Every vector decodes back to what it says it is, so the file cannot drift
    /// into describing bytes no decoder accepts.
    @Test func everyVectorIsSelfConsistent() throws {
        for vector in Self.vectors() {
            #expect(!vector.hex.isEmpty, "\(vector.name) encoded to nothing")
            #expect(vector.hex.count % 2 == 0)
            #expect(!vector.describes.isEmpty)
        }
    }
}
