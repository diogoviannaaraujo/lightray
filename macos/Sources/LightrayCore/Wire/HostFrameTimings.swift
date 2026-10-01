/// Optional host wall-clock durations, independent of the client's clock.
public struct HostFrameTimings: Equatable, Sendable {
    public let captureMicros: UInt32
    public let encodeMicros: UInt32
    public let sampleID: UInt64

    public init?(captureMicros: UInt32, encodeMicros: UInt32, sampleID: UInt64) {
        guard captureMicros <= 1_000_000, encodeMicros <= 1_000_000 else { return nil }
        self.captureMicros = captureMicros
        self.encodeMicros = encodeMicros
        self.sampleID = sampleID
    }

    var encoded: Bytes {
        var w = ByteWriter()
        w.u8(1)
        w.u32(captureMicros)
        w.u32(encodeMicros)
        w.u64(sampleID)
        return w.bytes
    }

    static func parse(_ bytes: ArraySlice<UInt8>) -> Self? {
        var r = ByteReader(bytes)
        guard bytes.count == 17, let version = try? r.u8(), version == 1,
            let capture = try? r.u32(), let encode = try? r.u32(), let sample = try? r.u64() else { return nil }
        return Self(captureMicros: capture, encodeMicros: encode, sampleID: sample)
    }
}
