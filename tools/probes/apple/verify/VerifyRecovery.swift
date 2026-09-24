// verify-recovery: checks recovery streams (HEVC + JSON manifest) with VideoToolbox, and writes the
// VideoToolbox reference streams the Windows encoders are compared against.
//
// Build:  swiftc -O -parse-as-library VerifyRecovery.swift ../shared/*.swift -o verify-recovery
// Use:    verify-recovery generate <out-dir>        VideoToolbox streams: idr, ltr
//         verify-recovery verify <file.json|dir>... one verdict line per stream
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

let lostFrames = Array(40...45)
let recoveryFrame = 46
let frameCount = 120

/// Frame `i` of a desktop on which a window is dragged and a line of text grows, so every
/// predicted frame carries real motion.
func movingDesktop(base: CVPixelBuffer, into pb: CVPixelBuffer, frame i: Int) {
    CVPixelBufferLockBaseAddress(base, .readOnly)
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []); CVPixelBufferUnlockBaseAddress(base, .readOnly) }
    memcpy(CVPixelBufferGetBaseAddress(pb), CVPixelBufferGetBaseAddress(base), CVPixelBufferGetDataSize(base))
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
    ctx.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1))
    ctx.fill(CGRect(x: 120 + 11 * i, y: 380 + 3 * i, width: 420, height: 260))
    ctx.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 120 + 11 * i, y: 380 + 3 * i + 232, width: 420, height: 28))
    for k in 0..<(i % 40) {
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 140 + 11 * i + (k % 20) * 19, y: 400 + 3 * i + (k / 20) * 22, width: 12, height: 16))
    }
}

func generate(outDir: URL) throws {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let w = 1920, h = 1080, fps = 60
    let base = makePixelBuffer(w, h)
    drawDesktop(into: base, variant: 0)
    let frame = makePixelBuffer(w, h)
    // LTR variants differ only in how often the receiver acknowledges decoded LTR frames: every
    // frame, or one frame per 250 ms (every 15th at 60 fps). Acks reach the encoder one frame late
    // and stop at the loss; frame 46 asks for ForceLTRRefresh.
    for scenario in ["idr", "ltr-ack-every-frame", "ltr-ack-every-250ms"] {
        let ltr = scenario.hasPrefix("ltr")
        let ackEvery = scenario == "ltr-ack-every-250ms" ? 15 : 1
        var session: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_HEVC,
                                         encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr, let s = session
        else { print("ERROR cannot create a low-latency HEVC encoder"); return }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: 20_000_000 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 100_000 as CFNumber)
        if ltr { VTSessionSetProperty(s, key: kVTCompressionPropertyKey_EnableLTR, value: kCFBooleanTrue) }
        VTCompressionSessionPrepareToEncodeFrames(s)

        var stream = Data()
        var frames: [RecoveryManifest.Frame] = []
        var pendingAcks: [CFNumber] = []
        for i in 0..<frameCount {
            movingDesktop(base: base, into: frame, frame: i)
            var opts: [CFString: Any] = [:]
            if i == 0 { opts[kVTEncodeFrameOptionKey_ForceKeyFrame] = true }
            if !pendingAcks.isEmpty { opts[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = pendingAcks as CFArray; pendingAcks = [] }
            if i == recoveryFrame {
                if ltr { opts[kVTEncodeFrameOptionKey_ForceLTRRefresh] = true } else { opts[kVTEncodeFrameOptionKey_ForceKeyFrame] = true }
            }
            let sem = DispatchSemaphore(value: 0)
            var out: CMSampleBuffer?
            let pts = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))
            VTCompressionSessionEncodeFrame(s, imageBuffer: frame, presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
                                            frameProperties: opts.isEmpty ? nil : opts as CFDictionary, infoFlagsOut: nil) { status, _, sb in
                if status == noErr { out = sb }
                sem.signal()
            }
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: pts)
            sem.wait()
            guard let sb = out else { print("ERROR encode failed at frame \(i)"); return }
            var keyframe = true
            var token: CFNumber? = nil
            if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]], let a = arr.first {
                keyframe = !((a[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
                if let t = a[kVTSampleAttachmentKey_RequireLTRAcknowledgementToken] { token = (t as! CFNumber) }
            }
            if let token, i < lostFrames[0], i % ackEvery == 0 { pendingAcks.append(token) }
            let bytes = HEVC.annexB(sb, withParameterSets: keyframe)
            stream.append(bytes)
            frames.append(.init(index: i, bytes: CMSampleBufferGetTotalSampleSize(sb), keyframe: keyframe))
        }
        VTCompressionSessionInvalidate(s)
        let note = ltr ? "LTR tokens of frames before 40 acknowledged every \(ackEvery) frame(s), one frame late; frame 46 encoded with ForceLTRRefresh" : "frame 46 forced to IDR"
        let manifest = RecoveryManifest(encoder: "videotoolbox", device: machineName(), scenario: scenario, width: w, height: h, fps: fps,
                                        lost: lostFrames, recovery: recoveryFrame, frames: frames, notes: note)
        let stem = outDir.appendingPathComponent("videotoolbox-\(scenario)")
        try stream.write(to: stem.appendingPathExtension("hevc"))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: stem.appendingPathExtension("json"))
        print("wrote \(stem.lastPathComponent).hevc (\(stream.count / 1024) KB)")
    }
}

func machineName() -> String {
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
    return String(cString: buf)
}

@main struct Main {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "generate":
            try generate(outDir: URL(fileURLWithPath: args.count > 1 ? args[1] : "."))
        case "verify":
            var manifests: [URL] = []
            for a in args.dropFirst() {
                let url = URL(fileURLWithPath: a)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: a, isDirectory: &isDir), isDir.boolValue {
                    let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                    manifests += items.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                } else {
                    manifests.append(url)
                }
            }
            for m in manifests { print(RecoveryVerifier.verify(manifestURL: m)) }
        default:
            print("usage: verify-recovery generate <out-dir> | verify <file.json|dir>...")
        }
    }
}
