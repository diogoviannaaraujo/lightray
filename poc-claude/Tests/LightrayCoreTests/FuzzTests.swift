import LightrayCore
import LightrayTestSupport
import Testing

/// Mutated and truncated datagrams must never crash or read past their buffer.
///
/// The read path is the only place a remote peer chooses the bytes, so it is the
/// only place where a bounds mistake is a security bug rather than a bug.
@Suite("Fuzz")
struct FuzzTests {

    /// Builds a valid datagram's chunk area, then hands mutations of it to every
    /// decoder. Nothing may trap; throwing is the correct answer.
    @Test func mutatedChunkSequencesNeverTrap() throws {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1200, alignment: 64)
        defer { buffer.deallocate() }
        var w = ByteWriter(buffer)
        let fragmentSite = try w.beginChunk(.mediaFragment)
        try FragmentHeader(stream: 1, flags: [.keyframe], frameID: 42, index: 0, count: 3,
                           stride: 400).encode(into: &w)
        try w.put([UInt8](repeating: 0x33, count: 400))
        w.endChunk(fragmentSite)
        let nackSite = try w.beginChunk(.nack)
        try Nack.encode(into: &w, stream: 1, entries: [NackEntry(frameID: 42, first: 1, count: 2)])
        w.endChunk(nackSite)
        let feedbackSite = try w.beginChunk(.feedback)
        try Feedback.encode(into: &w, baseSeq: 1, count: 16) { $0 % 3 == 0 ? nil : 1_000 + $0 * 100 }
        w.endChunk(feedbackSite)
        let valid = Array(w.contents)
        #expect(valid.count > 400)

        var random = SeededRandom(seed: 0xF0F0_F0F0)
        var survived = 0
        for iteration in 0..<200_000 {
            // Truncate at a random point, then flip a few bytes.
            var bytes = Array(valid.prefix(Int(random.next() % UInt64(valid.count + 1))))
            if !bytes.isEmpty {
                let flips = 1 + Int(random.next() % 4)
                for _ in 0..<flips {
                    let index = Int(random.next() % UInt64(bytes.count))
                    bytes[index] ^= UInt8(truncatingIfNeeded: random.next())
                }
            }
            // Every fourth case is pure noise rather than a mutated valid packet.
            if iteration % 4 == 0 {
                bytes = (0..<Int(random.next() % 1300)).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            }
            survived += Self.decodeEverything(bytes)
        }
        #expect(survived >= 0, "200,000 mutated or truncated chunk sequences, no trap")
    }

    /// Walks the chunk sequence and parses each body with the matching decoder.
    /// Returns how many chunks it got through, which the caller only uses to keep
    /// the work from being optimised away.
    static func decodeEverything(_ bytes: [UInt8]) -> Int {
        bytes.withUnsafeBytes { raw -> Int in
            guard raw.count > 0 else { return 0 }
            let span = RawSpan(_unsafeBytes: raw)
            var r = ByteReader(span)
            var parsed = 0
            while let chunk = try? r.nextChunk() {
                parsed += 1
                var body = ByteReader(chunk.body)
                switch chunk.knownType {
                case .mediaFragment:
                    if let fragment = try? body.fragment() { parsed += fragment.payload.byteCount }
                case .reliable:
                    if let segment = try? body.reliableSegment() { parsed += segment.payload.byteCount }
                case .datagram:
                    _ = try? body.u8()
                    parsed += body.rest().byteCount
                case .feedback:
                    _ = try? Feedback.decode(&body) { _, _ in }
                case .nack:
                    _ = try? Nack.decode(&body) { _ in }
                case .frameAck:
                    try? FrameAck.decode(&body) { _ in }
                case .refreshRequest:
                    _ = try? RefreshRequest.decode(&body)
                case .ping, .park:
                    _ = try? body.u32()
                case .pong:
                    _ = try? Pong.decode(&body)
                case .resume:
                    _ = try? body.u8()
                case .close:
                    _ = try? body.u16()
                case nil:
                    break   // unknown type: skipped
                }
            }
            return parsed
        }
    }

    /// The same treatment for whole datagrams, headers and handshake packets.
    @Test func mutatedHeadersAndHandshakesNeverTrap() throws {
        var random = SeededRandom(seed: 0x1234_5678)
        var accepted = 0
        for _ in 0..<200_000 {
            let length = Int(random.next() % 80)
            let bytes = (0..<length).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            bytes.withUnsafeBytes { raw in
                if raw.count > 0 {
                    let span = RawSpan(_unsafeBytes: raw)
                    var r = ByteReader(span)
                    if (try? PacketHeader.decode(&r)) != nil { accepted += 1 }
                }
                _ = PacketHeader.peekSessionID(raw)
                _ = PacketHeader.peekTransportSeq(raw)
                if raw.count > 0 {
                    let span = RawSpan(_unsafeBytes: raw)
                    var r2 = ByteReader(span)
                    _ = try? InitPrefix.decode(&r2)
                    var r3 = ByteReader(span)
                    _ = try? ResponsePrefix.decode(&r3)
                    var r4 = ByteReader(span)
                    _ = try? SessionUnknown.decode(&r4)
                    var r5 = ByteReader(span)
                    _ = try? InitBody.decode(&r5)
                    var r6 = ByteReader(span)
                    _ = try? ResponseBody.decode(&r6)
                    var r7 = ByteReader(span)
                    _ = try? ControlBody.decode(&r7)
                }
                _ = try? FrameHeader.parse(raw)
            }
        }
        #expect(accepted >= 0, "200,000 random datagrams parsed without a trap")
    }

    /// A frame header claiming a longer ext block than it has must be rejected,
    /// not read past.
    @Test func aFrameHeaderWithALyingExtLengthIsRejected() {
        // frame_type, ref_kind, flags, generation, capture_time, ext_len = 0xFFFF
        let bytes: [UInt8] = [0, 0, 0, 0, 1, 0, 0, 0, 2, 0xFF, 0xFF]
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            #expect(throws: WireError.truncated) { try FrameHeader.parse(raw) }
        }
    }
}
