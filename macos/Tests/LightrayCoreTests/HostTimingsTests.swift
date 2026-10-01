import Testing
@testable import LightrayCore

private func telemetryFrame(_ values: [Bytes]) -> Bytes {
    var w = ByteWriter()
    w.append(FrameHeader(frameType: .predicted, refKind: .previous, captureTimeMicros: 42).encoded.prefix(11))
    var ext = ByteWriter()
    for value in values { ext.tlv(FrameHeader.Extension.hostTimings, value) }
    w.u16(UInt16(ext.count)); w.append(ext.bytes)
    return w.bytes + [99]
}

@Test func hostTimingsGoldenAndRoundTrip() throws {
    let sample = try #require(HostFrameTimings(captureMicros: 1000, encodeMicros: 2000, sampleID: 0x0102030405060708))
    #expect(sample.encoded == [1, 0, 0, 3, 232, 0, 0, 7, 208, 1, 2, 3, 4, 5, 6, 7, 8])
    let frame = telemetryFrame([sample.encoded])
    let parsed = try #require(FrameHeader.parse(frame))
    #expect(parsed.header.hostTimings == sample)
    #expect(Bytes(frame[parsed.payloadOffset...]) == [99])
    #expect(parsed.header.encoded.count == 33)
    #expect(FrameHeader.parse(telemetryFrame([]))?.header.hostTimings == nil)
}

@Test func invalidOptionalTimingsDoNotDiscardVideo() throws {
    let sample = try #require(HostFrameTimings(captureMicros: 0, encodeMicros: 1_000_000, sampleID: .max))
    var future = sample.encoded; future[0] = 2
    var outOfRange = sample.encoded; outOfRange[1] = 255
    for values in [[future], [outOfRange], [Bytes(sample.encoded.dropLast())], [sample.encoded + [0]], [sample.encoded, sample.encoded], [future, sample.encoded], [sample.encoded, sample.encoded, sample.encoded]] {
        let parsed = try #require(FrameHeader.parse(telemetryFrame(values)))
        #expect(parsed.header.hostTimings == nil)
    }
    #expect(HostFrameTimings(captureMicros: 1_000_001, encodeMicros: 0, sampleID: 0) == nil)
    #expect(HostFrameTimings(captureMicros: 0, encodeMicros: .max, sampleID: 0) == nil)
    var unknown = telemetryFrame([sample.encoded]); unknown[13] = 0xEF
    #expect(try #require(FrameHeader.parse(unknown)).header.hostTimings == nil)
    var truncated = telemetryFrame([sample.encoded]); truncated[15] = 30
    #expect(FrameHeader.parse(truncated) == nil)
}

@Test func optionalTimingsFitExtensionBudget() throws {
    let sample = try #require(HostFrameTimings(captureMicros: 1, encodeMicros: 2, sampleID: 3))
    let config = CodecConfig(vps: Bytes(repeating: 1, count: 65_518), sps: [1], pps: [1])
    let legacy = FrameHeader(frameType: .idr, refKind: .none, captureTimeMicros: 0, codecConfig: config)
    var timed = legacy; timed.hostTimings = sample
    #expect(timed.encoded == legacy.encoded)
    #expect(try #require(FrameHeader.parse(timed.encoded)).header.hostTimings == nil)
}
