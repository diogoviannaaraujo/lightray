import LightrayCore
import LightrayEngine

/// Synthetic frames with realistic sizes, so the pacer, fragmenter and
/// retransmit store see the shape they will see in production.
///
/// Phase 0 measured the numbers this imitates: at equal bitrate an HEVC
/// low-latency P-frame runs to about 3× the per-frame budget at p99, and an IDR
/// is many times a P-frame.
public struct SyntheticFrameSource {
    public var stream: UInt8
    public var bitrate: UInt32
    public var framerate: UInt16
    /// A forced IDR every N frames; 0 means only on demand.
    public var idrInterval: Int
    /// HEVC VPS + SPS + PPS with 4-byte NAL lengths: 81 bytes on the encoders
    /// Phase 0 measured. Carried on every IDR, because they are not in-band and
    /// no decoder can be built without them.
    public var codecConfig: [UInt8]
    public var ltrMark = true
    /// True for a realtime stream: every frame stands alone, so none of them
    /// reference anything and none can be undecodable.
    public var independentFrames = false

    private var frameIndex = 0
    private var random: SeededRandom

    public init(stream: UInt8, bitrate: UInt32 = 20_000_000, framerate: UInt16 = 60,
                idrInterval: Int = 0, independentFrames: Bool = false, seed: UInt64 = 0xC0DEC) {
        self.independentFrames = independentFrames
        self.stream = stream
        self.bitrate = bitrate
        self.framerate = framerate
        self.idrInterval = idrInterval
        self.codecConfig = (0..<81).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
        self.random = SeededRandom(seed: seed)
    }

    public var averageFrameBytes: Int { Int(bitrate) / 8 / Int(max(framerate, 1)) }

    /// The next frame. `forceIDR` is how the app answers `.refreshRequired(.idr)`.
    public mutating func next(at now: Instant, forceIDR: Bool = false,
                              ltrCandidates: [UInt32] = []) -> EncodedFrame {
        defer { frameIndex += 1 }
        let periodic = idrInterval > 0 && frameIndex % idrInterval == 0
        let isIDR = forceIDR || periodic || frameIndex == 0
        let average = averageFrameBytes

        let size: Int
        if isIDR {
            size = average * 12
        } else if !ltrCandidates.isEmpty {
            // An LTR refresh frame is 1.4–2.2× a P-frame on synthetic content.
            size = Int(Double(average) * (1.4 + random.unit() * 0.8))
        } else {
            size = max(200, Int(Double(average) * (0.4 + random.unit() * 1.6)))
        }

        let storage = HeapStorage(byteCount: size, fill: UInt8(truncatingIfNeeded: frameIndex))
        // Make the payload distinguishable, so a reassembly bug shows up as a
        // content mismatch and not just a length mismatch.
        let bytes = storage.mutableBytes
        if bytes.count >= 4 {
            bytes.storeBytes(of: UInt32(frameIndex).bigEndian, toByteOffset: 0, as: UInt32.self)
        }

        var refKind: RefKind = isIDR || independentFrames ? .none : .previous
        if !isIDR, !independentFrames, !ltrCandidates.isEmpty { refKind = .ltrAny }

        return EncodedFrame(stream: stream, storage: storage,
                            frameType: isIDR && !independentFrames ? .idr : .predicted,
                            refKind: refKind, refFrameID: nil, ltrMark: ltrMark,
                            captureTimeMicros: now.microsTruncated,
                            codecConfig: isIDR ? codecConfig : nil)
    }
}
