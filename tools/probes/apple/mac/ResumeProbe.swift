// ResumeProbe: measures the VideoToolbox costs that sit on Lightray's resume path.
// Build: swiftc -O -parse-as-library ResumeProbe.swift ../shared/SyntheticDesktop.swift -o resumeprobe
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import VideoToolbox

// MARK: - Timing

@inline(__always) func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
func ms(_ ns: UInt64) -> Double { Double(ns) / 1e6 }

func pct(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    let i = min(s.count - 1, max(0, Int((p / 100.0) * Double(s.count - 1) + 0.5)))
    return s[i]
}

// Synthetic desktop content: ../shared/SyntheticDesktop.swift

// MARK: - Encoder wrapper

final class Encoder {
    let session: VTCompressionSession
    let createMs: Double
    let prepareMs: Double
    var lastParams: CMFormatDescription?

    init(w: Int, h: Int, bitrate: Int, fps: Int, ltr: Bool) {
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        var s: VTCompressionSession?
        let t0 = nowNs()
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_HEVC,
                                            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        let t1 = nowNs()
        precondition(st == noErr, "VTCompressionSessionCreate \(st)")
        let sess = s!
        func set(_ k: CFString, _ v: CFTypeRef) {
            let r = VTSessionSetProperty(sess, key: k, value: v)
            if r != noErr { print("  warn: set \(k) -> \(r)") }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 100_000 as CFNumber)
        if ltr { set(kVTCompressionPropertyKey_EnableLTR, kCFBooleanTrue) }
        let t2 = nowNs()
        let pr = VTCompressionSessionPrepareToEncodeFrames(sess)
        let t3 = nowNs()
        precondition(pr == noErr, "Prepare \(pr)")
        session = sess
        createMs = ms(t1 - t0)
        prepareMs = ms(t3 - t2)
    }

    struct Out { var bytes: Int; var latencyMs: Double; var sync: Bool; var sample: CMSampleBuffer }

    /// Encodes one frame synchronously (waits for the output) and returns size and latency.
    func encode(_ pb: CVPixelBuffer, pts: CMTime, forceKey: Bool) -> Out {
        let sem = DispatchSemaphore(value: 0)
        var result: Out?
        let props: CFDictionary? = forceKey ? ([kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary) : nil
        let t0 = nowNs()
        let st = VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                                 frameProperties: props, infoFlagsOut: nil) { status, _, sbuf in
            let t1 = nowNs()
            guard status == noErr, let sbuf = sbuf else { print("  encode status \(status)"); sem.signal(); return }
            var sync = true
            if let arr = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false) as? [[CFString: Any]],
               let first = arr.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool { sync = !notSync }
            result = Out(bytes: CMSampleBufferGetTotalSampleSize(sbuf), latencyMs: ms(t1 - t0), sync: sync, sample: sbuf)
            sem.signal()
        }
        precondition(st == noErr, "EncodeFrame \(st)")
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: pts)
        sem.wait()
        if let r = result { lastParams = CMSampleBufferGetFormatDescription(r.sample) }
        return result!
    }

    deinit { VTCompressionSessionInvalidate(session) }
}

// MARK: - Decoder

func decodeCold(_ sample: CMSampleBuffer) -> (createMs: Double, firstDecodeMs: Double, warmDecodeMs: Double) {
    let fmt = CMSampleBufferGetFormatDescription(sample)!
    var ds: VTDecompressionSession?
    let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                 kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    let spec = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
    let t0 = nowNs()
    let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: spec,
                                          imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &ds)
    let t1 = nowNs()
    precondition(st == noErr, "VTDecompressionSessionCreate \(st)")
    func decodeOnce() -> Double {
        let sem = DispatchSemaphore(value: 0)
        let a = nowNs()
        var b: UInt64 = 0
        let r = VTDecompressionSessionDecodeFrame(ds!, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, _, _, _ in
            if status != noErr { print("  decode status \(status)") }
            b = nowNs(); sem.signal()
        }
        precondition(r == noErr, "DecodeFrame \(r)")
        sem.wait()
        return ms(b - a)
    }
    let first = decodeOnce()
    var warm: [Double] = []
    for _ in 0..<10 { warm.append(decodeOnce()) }
    VTDecompressionSessionInvalidate(ds!)
    return (ms(t1 - t0), first, pct(warm, 50))
}

// MARK: - Main

@main struct Main {
    static func main() {
        print("# Lightray resume probe — \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let configs: [(String, Int, Int, [Int])] = [("1080p", 1920, 1080, [10_000_000, 20_000_000]),
                                                   ("1440p", 2560, 1440, [20_000_000, 40_000_000]),
                                                   ("2160p", 3840, 2160, [20_000_000, 40_000_000])]
        let fps = 60
        let idleSeconds = Double(CommandLine.arguments.dropFirst().first ?? "5") ?? 5
        let only = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
        for (name, w, h, rates) in configs where only.isEmpty || name == only {
            let a = makePixelBuffer(w, h), b = makePixelBuffer(w, h)
            drawDesktop(into: a, variant: 0)
            drawDesktop(into: b, variant: 1)
            for rate in (only.isEmpty ? rates : [rates[1]]) {
                // Cold: a new session and its first frame (what a torn-down pipeline pays).
                var creates: [Double] = [], prepares: [Double] = [], coldFirst: [Double] = []
                var coldIDRBytes = 0
                for _ in 0..<5 {
                    let e = Encoder(w: w, h: h, bitrate: rate, fps: fps, ltr: true)
                    creates.append(e.createMs); prepares.append(e.prepareMs)
                    let o = e.encode(a, pts: CMTime(value: 0, timescale: 600), forceKey: true)
                    coldFirst.append(o.latencyMs); coldIDRBytes = o.bytes
                }
                // Warm: one session streams 2 s of the same desktop (as parked-but-alive), idles, then
                // encodes (1) a forced IDR, (2) a plain P-frame of the unchanged screen and (3) a plain
                // P-frame after the screen changed — the three things a resume can send.
                let e = Encoder(w: w, h: h, bitrate: rate, fps: fps, ltr: true)
                var t: Int64 = 0
                var steadyP: [Int] = [], steadyLat: [Double] = []
                for i in 0..<120 {
                    let o = e.encode(a, pts: CMTime(value: t, timescale: 600), forceKey: i == 0)
                    t += 10
                    if i >= 60 { steadyP.append(o.bytes); steadyLat.append(o.latencyMs) }
                }
                Thread.sleep(forTimeInterval: idleSeconds)
                let warmIDR = e.encode(a, pts: CMTime(value: t, timescale: 600), forceKey: true); t += 10
                var warmIDRs: [Double] = []
                for _ in 0..<5 {
                    Thread.sleep(forTimeInterval: 0.2)
                    warmIDRs.append(e.encode(a, pts: CMTime(value: t, timescale: 600), forceKey: true).latencyMs); t += 10
                }
                for _ in 0..<30 { _ = e.encode(a, pts: CMTime(value: t, timescale: 600), forceKey: false); t += 10 }
                Thread.sleep(forTimeInterval: idleSeconds)
                let pSame = e.encode(a, pts: CMTime(value: t, timescale: 600), forceKey: false); t += 10
                for _ in 0..<30 { _ = e.encode(a, pts: CMTime(value: t, timescale: 600), forceKey: false); t += 10 }
                Thread.sleep(forTimeInterval: idleSeconds)
                let pChanged = e.encode(b, pts: CMTime(value: t, timescale: 600), forceKey: false); t += 10
                let dec = decodeCold(warmIDR.sample)
                print(String(format: "%@ HEVC %2d Mbps | create %.1f ms, prepare %.1f ms, cold first IDR %.1f ms (p50 of 5; max %.1f) %6.1f KB",
                             name, rate / 1_000_000, pct(creates, 50), pct(prepares, 50), pct(coldFirst, 50), pct(coldFirst, 100),
                             Double(coldIDRBytes) / 1024))
                print(String(format: "      warm IDR after %.0fs idle %.1f ms (%6.1f KB, sync=%@); warm IDR p50 %.1f ms; steady P p50 %.1f ms, %.1f KB",
                             idleSeconds, warmIDR.latencyMs, Double(warmIDR.bytes) / 1024, warmIDR.sync ? "yes" : "no",
                             pct(warmIDRs, 50), pct(steadyLat, 50), pct(steadyP.map(Double.init), 50) / 1024))
                print(String(format: "      resume without IDR: P(unchanged) %.1f KB in %.1f ms; P(changed) %.1f KB in %.1f ms (sync=%@)",
                             Double(pSame.bytes) / 1024, pSame.latencyMs, Double(pChanged.bytes) / 1024, pChanged.latencyMs,
                             pChanged.sync ? "yes" : "no"))
                print(String(format: "      decoder: create %.1f ms, first IDR decode %.1f ms, warm IDR decode p50 %.1f ms",
                             dec.createMs, dec.firstDecodeMs, dec.warmDecodeMs))
            }
        }
    }
}
