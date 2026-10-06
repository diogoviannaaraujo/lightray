import Testing

@testable import LightrayCore

/// The version 0 examples in `docs/video.md`, `docs/feedback.md` and `docs/input.md`: each parses
/// and re-encodes byte for byte.
func hex(_ s: String) -> Bytes { Bytes(hex: s)! }

func single(_ bytes: Bytes) -> Chunk? {
    let parsed = Chunk.parse(bytes)
    return parsed.chunks.count == 1 ? parsed.chunks[0] : nil
}

@Test func feedbackExample() throws {
    let bytes = hex("10002300000064000a000f4240dbc0000000190025000d0032000f000a001900010500000003")
    guard case .feedback(let f) = single(bytes) else { Issue.record("not FEEDBACK"); return }
    #expect(f.baseSeq == 100)
    #expect(f.received.count == 10)
    let missing = f.received.enumerated().filter { !$0.element }.map { 100 + $0.offset }
    #expect(missing == [102, 105])
    #expect(f.arrivals.map(\.time) == [1_000_000, 1_000_100, 1_000_248, 1_000_300, 1_000_500, 1_000_560, 1_000_600, 1_000_700])
    #expect(f.acks == [ReliableAck(stream: 5, msgSeq: 3)])
    #expect(Chunk.feedback(f).encoded == bytes)

    // Built from arrivals, the same report.
    let rebuilt = Feedback(
        baseSeq: 100, count: 10,
        arrivals: f.arrivals.map { (Int($0.seq - 100), $0.time) }, acks: f.acks)
    #expect(rebuilt == f)
}

@Test func feedbackAcknowledgementOnly() {
    let bytes = hex("1000110000000000000000000000010500000004")
    guard case .feedback(let f) = single(bytes) else { Issue.record("not FEEDBACK"); return }
    #expect(f.received.isEmpty && f.deltas.isEmpty)
    #expect(f.acks == [ReliableAck(stream: 5, msgSeq: 4)])
    #expect(Chunk.feedback(f).encoded == bytes)
}

@Test func feedbackDeltasClampBeforeScaling() {
    // Two arrivals a second apart: far beyond ±131 ms. Chained from the reconstructed arrival.
    // The reporter chains from where the reader will think the previous packet arrived, so the
    // error of one clamp is not added to the next.
    let f = Feedback(baseSeq: 0, count: 3, arrivals: [(0, 0), (1, 1_000_000), (2, 1_000_040)], acks: [])
    #expect(f.deltas == [0, Int16.max, Int16.max])
    #expect(f.arrivals.map(\.time) == [0, 131_068, 262_136])
    let near = Feedback(baseSeq: 0, count: 3, arrivals: [(0, 10), (1, 110), (2, 102)], acks: [])
    #expect(near.deltas == [0, 25, -2])
}

@Test func feedbackWithLengthsThatDoNotConsumeTheBodyIsDiscarded() {
    var bytes = hex("1000110000000000000000000000010500000004")
    bytes[2] = 0x12
    bytes.append(0)
    #expect(Chunk.parse(bytes).malformed == 1)
}

@Test func nackExample() {
    let bytes = hex("110019010000000a000000030000000b000700010000000c00000000")
    let expected = Nack(stream: 1, entries: [
        NackEntry(frameID: 10, first: 0, count: 3), NackEntry(frameID: 11, first: 7, count: 1),
        NackEntry(frameID: 12, first: 0, count: 0),
    ])
    #expect(single(bytes) == .nack(expected))
    #expect(Chunk.nack(expected).encoded == bytes)
}

@Test(arguments: [1, 2, 3, 4, 6, 7, 8, 9, 11])
func malformedFrameAcknowledgementDoesNotDiscardFollowingChunk(length: Int) {
    var w = ByteWriter()
    w.tlv(ChunkType.frameAck, Bytes(repeating: 0, count: length))
    Chunk.ping(id: 9).write(to: &w)
    let parsed = Chunk.parse(w.bytes)
    #expect(parsed.malformed == 1)
    #expect(parsed.chunks == [.ping(id: 9)])
}

@Test func refreshRequestExample() {
    let bytes = hex("13000f010000000001e0000001eb00000007")
    let expected = RefreshRequest(stream: 1, reason: .loss, preferred: .ltr, lastGoodFrame: 480, lostFrame: 491, reqID: 7)
    #expect(single(bytes) == .refreshRequest(expected))
    #expect(Chunk.refreshRequest(expected).encoded == bytes)
    var bad = bytes
    bad[4] = 9
    #expect(Chunk.parse(bad).malformed == 1)
}

@Test func pingPongExamples() {
    #expect(single(hex("30000400000009")) == .ping(id: 9))
    #expect(single(hex("31000800000009000005dc")) == .pong(id: 9, holdMicros: 1500))
    #expect(Chunk.pong(id: 9, holdMicros: 1500).encoded == hex("31000800000009000005dc"))
}

@Test func reliableAndDatagramExamples() {
    let reliable = hex("02000c000000000300010002010203")
    let segment = ReliableSegment(stream: 0, msgSeq: 3, segIndex: 1, segCount: 2, payload: [1, 2, 3])
    #expect(single(reliable) == .reliable(segment))
    #expect(Chunk.reliable(segment).encoded == reliable)
    #expect(single(hex("0300060668656c6c6f")) == .datagram(stream: 6, payload: Bytes("hello".utf8)))
}

@Test func mediaFragmentExample() {
    let bytes = hex("01001801010000000700040005047d03010100a0a1a2a3a4a5a6a7")
    guard case .mediaFragment(let f) = single(bytes) else { Issue.record("not a fragment"); return }
    #expect(f.stream == 1 && f.flags == MediaFragment.Flag.keyframe && f.frameID == 7)
    #expect(f.index == 4 && f.count == 5 && f.stride == 1149)
    #expect(Array(f.payload) == hex("a0a1a2a3a4a5a6a7"))
    #expect(Chunk.mediaFragment(f).encoded == bytes)
    #expect(MediaFragment.stride(forDatagramSize: 1200) == 1149)
}

@Test func invalidFragmentsAreDiscarded() {
    func fragment(index: UInt16, count: UInt16, stride: UInt16, payload: Int, fec: UInt8 = 0) -> Bytes {
        var w = ByteWriter()
        MediaFragment(
            stream: 1, flags: 0, frameID: 1, index: index, count: count, stride: stride,
            payload: Bytes(repeating: 7, count: payload)[...]
        ).write(to: &w)
        var bytes = w.bytes
        bytes[18] = fec
        return bytes
    }
    #expect(Chunk.parse(fragment(index: 0, count: 2, stride: 4, payload: 4)).malformed == 0)
    #expect(Chunk.parse(fragment(index: 0, count: 2, stride: 4, payload: 3)).malformed == 1)
    #expect(Chunk.parse(fragment(index: 1, count: 2, stride: 4, payload: 3)).malformed == 0)
    #expect(Chunk.parse(fragment(index: 2, count: 2, stride: 4, payload: 3)).malformed == 1)
    #expect(Chunk.parse(fragment(index: 0, count: 0, stride: 4, payload: 3)).malformed == 1)
    #expect(Chunk.parse(fragment(index: 0, count: 1, stride: 0, payload: 3)).malformed == 1)
    #expect(Chunk.parse(fragment(index: 0, count: 1, stride: 4, payload: 5)).malformed == 1)
    #expect(Chunk.parse(fragment(index: 0, count: 1, stride: 4, payload: 3, fec: 1)).malformed == 1)
}

@Test func closeExample() {
    #expect(single(hex("3400020001")) == .close(.appRequest))
    #expect(single(hex("340003000100")) == .close(.appRequest))
    #expect(single(hex("3400020777")) == .close(.normal))
    #expect(Chunk.parse(hex("34000100")).malformed == 1)
}

/// Conformance tests 12 and 13: unknown types are skipped, a malformed chunk is discarded alone,
/// and a truncated tail stops parsing without undoing what came before.
@Test func chunkParsingContainsErrors() {
    let ping = Chunk.ping(id: 1).encoded
    let unknown: Bytes = [0x7e, 0x00, 0x02, 0xaa, 0xbb]
    let malformedPong: Bytes = [0x31, 0x00, 0x01, 0x00]
    let parsed = Chunk.parse(unknown + ping + malformedPong + ping + [0x30, 0x00])
    #expect(parsed.chunks == [.unknown(type: 0x7e), .ping(id: 1), .ping(id: 1)])
    #expect(parsed.malformed == 1)
    #expect(Chunk.parse(ping + [0x30, 0x00, 0x09, 0x01]).chunks == [.ping(id: 1)])
    #expect(Chunk.parse(ping + [0, 0, 0, 0, 0]).chunks == [.ping(id: 1), .padding])
}

@Test func handshakeParameterRules() {
    func params(_ hexString: String) -> Result<HandshakeParams, HandshakeError> {
        Result { () throws(HandshakeError) in try HandshakeParams.decode(hex(hexString)[...]) }
    }
    #expect((try? params("0500020100").get())?.maxDatagramSize == 256)
    #expect((try? params("0500020100" + "fe0001aa").get())?.maxDatagramSize == 256)  // unknown TLV skipped
    #expect((try? params("05000201000500020100").get()) == nil)  // duplicate
    #expect((try? params("050003010000").get()) == nil)  // wrong length
    #expect((try? params("0500020100ff").get()) == nil)  // one trailing byte
    #expect((try? params("0500040100").get()) == nil)  // overruns
    #expect((try? params("04000400010100").get()) == nil)  // stream id 0
    #expect((try? params("0400080101010001010100").get()) == nil)  // duplicate id
    #expect((try? params("04000401050100").get()) == nil)  // camera kind is reserved
    #expect((try? params("04000401010104").get()) == nil)  // unassigned class
    #expect((try? params("0400000500020100").get()) == nil)  // empty table
}

/// The IDR example in `docs/video.md`: 13 fixed bytes, an 83-byte extension area holding VPS,
/// SPS and PPS of 24, 38 and 6 bytes, and a 327-byte payload.
@Test func idrFrameExample() throws {
    let frame = FrameExamples.idr
    #expect(frame.count == 423)
    let (header, offset) = try #require(FrameHeader.parse(frame))
    #expect(header.frameType == .idr && header.refKind == .none && header.flags == FrameHeader.Flag.ltrMark)
    #expect(header.configGeneration == 3 && header.captureTimeMicros == 123_456)
    let config = try #require(header.codecConfig)
    #expect([config.vps.count, config.sps.count, config.pps.count] == [24, 38, 6])
    #expect(offset == 13 + 83)
    #expect(header.encoded == Array(frame[0..<offset]))
}

@Test func predictedFrameHeaderExamples() throws {
    let ltr = hex("0102000000000100000005000010920000")
    let (header, offset) = try #require(FrameHeader.parse(ltr))
    #expect(header.refKind == .ltr && header.refFrameID == 4242 && header.configGeneration == 1)
    #expect(offset == 17 && header.encoded == ltr)
    let any = hex("01030000000001000000050000")
    #expect(FrameHeader.parse(any)?.header.refKind == .ltrAny)
    #expect(FrameHeader.parse(Array(ltr.prefix(10))) == nil)
    // An IDR without CODEC_CONFIG is rejected.
    #expect(FrameHeader.parse(hex("00000000000001000000050000")) == nil)
}

@Test(arguments: [UInt16(0), 1, 64, 65, .max])
func parityLastLengthIsValidated(length: UInt16) throws {
    let fragment = MediaFragment(stream: 1, flags: MediaFragment.Flag.parity, frameID: 1, index: 0, count: 1, stride: 64, fec: .init(maxBlockLength: 1, parityPerBlock: 1, lastLength: length), payload: Bytes(repeating: 0, count: 64)[...])
    let parsed = Chunk.parse(Chunk.mediaFragment(fragment).encoded)
    if (1...64).contains(length) {
        #expect(parsed.chunks == [.mediaFragment(fragment)])
    } else {
        #expect(parsed.chunks.isEmpty)
        #expect(parsed.malformed == 1)
    }
}

@Test(arguments: [0, 1, 2])
func emptyCodecParameterSetsAreRejected(index: Int) {
    var sets: [Bytes] = [[0x40, 1], [0x42, 1], [0x44, 1]]
    sets[index] = []
    let header = FrameHeader(frameType: .idr, refKind: .none, captureTimeMicros: 0, codecConfig: CodecConfig(vps: sets[0], sps: sets[1], pps: sets[2]))
    #expect(FrameHeader.parse(header.encoded) == nil)
}

enum FrameExamples {
    static let idr = hex(
        "000001000000030001e24000530100500000001840010c01ffff01600000030090000003000003003cba02400000002642010101600000030090000003000003003ca0884596e96f0b9a020000030002000003003c10000000064401c0718112000001432801ac1ae0f33d5fdcfddf03600717810da9f57f7bb115b7924631e1020000cacc5d6c1c47cdb924cb879dd8cd3e9efad4eb38f5abc256ca0d205c7abc3897c1456af493a979ed56e5d4411b5d6d972bad41ed61679250c54bd927454a389f0ce54ba83c5be0ba8b8ff2ea1e0aa497e49ec2fa2d3d272d6e188d578c2f27e6f449751f96f27ff5ae8352f2988bf52c1aa503dce248121b4042e5b3faf9c3adf9fe7ee3c06bfe1199fa8b9dbfd30090fed9f9eeee3be33dc398516216bdafea5bbbeaac3ec37adc7fa611e4a3b589aee7e0fbe17cadea66770a486e9ae25821bd4b8925e02d311d842c4ffda14eb6c4f1b1598211604264759329ef4c1e7fb35f201bdfb25e12f9b0778d61e5eb242bf2202706106410a5ad36084f2cf64b27a9a039ed2f3c5c784c2129387bf43ee726767425c27a3a514fde71cef2456b108e7a27c0"
    )
}

/// Provisional FEC scheme 1: its parameters on every fragment, parity flagged and counted apart.
@Test func reedSolomonFragments() {
    let fec = MediaFragment.FEC(maxBlockLength: 231, parityPerBlock: 2, lastLength: 3)
    func encoded(_ f: MediaFragment) -> Bytes {
        var w = ByteWriter()
        f.write(to: &w)
        return w.bytes
    }
    func fragment(flags: UInt8 = 0, index: UInt16, count: UInt16 = 5, payload: Int, fec: MediaFragment.FEC? = fec) -> Bytes {
        encoded(MediaFragment(
            stream: 1, flags: flags, frameID: 9, index: index, count: count, stride: 4, fec: fec,
            payload: Bytes(repeating: 7, count: payload)[...]))
    }
    let parity = fragment(flags: MediaFragment.Flag.parity, index: 1, payload: 4)
    // The extension grows from `01 01 00` to seven bytes: scheme 1, 231, 2, then 3 as a u16.
    #expect(Array(parity[15..<23]) == hex("07010501e7020003"))
    guard case .mediaFragment(let f) = Chunk.parse(parity).chunks.first else {
        Issue.record("did not parse")
        return
    }
    #expect(f.isParity && f.fec == fec && Chunk.mediaFragment(f).encoded == parity)
    #expect(MediaFragment.stride(forDatagramSize: 1200, fec: true) == 1145)
    #expect(Chunk.parse(fragment(index: 4, payload: 3)).malformed == 0)
    // The last data fragment must be as long as the extension says.
    #expect(Chunk.parse(fragment(index: 4, payload: 2)).malformed == 1)
    // Parity: a whole stride, an index within blocks × parity, and only with scheme 1.
    #expect(Chunk.parse(fragment(flags: MediaFragment.Flag.parity, index: 1, payload: 3)).malformed == 1)
    #expect(Chunk.parse(fragment(flags: MediaFragment.Flag.parity, index: 2, payload: 4)).malformed == 1)
    #expect(Chunk.parse(fragment(flags: MediaFragment.Flag.parity, index: 0, payload: 4, fec: nil)).malformed == 1)
    // Parameters that describe no code, and schemes not implemented, discard the fragment.
    let tooLong = MediaFragment.FEC(maxBlockLength: 255, parityPerBlock: 1, lastLength: 3)
    #expect(Chunk.parse(fragment(index: 0, count: 255, payload: 4, fec: tooLong)).malformed == 1)
    var scheme2 = fragment(index: 4, payload: 3)
    scheme2[18] = 2
    #expect(Chunk.parse(scheme2).malformed == 1)
}

@Test func capabilitiesAreOfferedAndAnsweredInTheHandshake() throws {
    let params = HandshakeParams(timestamp: 5, capabilities: Capability.fec, maxDatagramSize: 1200)
    #expect(try HandshakeParams.decode(params.encoded[...]) == params)
    // Type 3, length 1, the FEC bit, between TIMESTAMP and MAX_DATAGRAM_SIZE.
    #expect(Array(params.encoded[11..<15]) == hex("03000104"))
    #expect(throws: HandshakeError.self) { try HandshakeParams.decode(hex("0300020400")[...]) }
}
