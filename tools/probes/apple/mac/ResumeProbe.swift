// ResumeProbe: measures the VideoToolbox costs that sit on Lightray's resume path.
// Build: swiftc -O -parse-as-library ResumeProbe.swift -o resumeprobe
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

// MARK: - Synthetic desktop content

struct Rng {
    var s: UInt64
    mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 }
    mutating func unit() -> Double { Double(next() % 1_000_000) / 1_000_000.0 }
}

let words = ["func", "let", "var", "return", "struct", "import", "Lightray", "session", "packet", "frame",
             "resume", "park", "encoder", "decoder", "latency", "if", "else", "guard", "while", "for",
             "in", "0x7f", "self", "UInt32", "Double", "try", "await", "async", "stream", "keyframe",
             "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "remote", "desktop"]

/// Draws a desktop: wallpaper, a code editor, a document window and a dock. `variant` changes the
/// text and window positions so that two variants differ the way a screen changes over minutes.
func drawDesktop(into pb: CVPixelBuffer, variant: Int) {
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { fatalError("no CGContext") }
    let W = CGFloat(w), H = CGFloat(h)
    let scale = W / 1920.0
    // Wallpaper: smooth gradient plus soft blobs (photo-like, compresses well).
    let grad = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.10, green: 0.18, blue: 0.35, alpha: 1),
                                                   CGColor(red: 0.55, green: 0.30, blue: 0.45, alpha: 1)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: W, y: H), options: [])
    var rng = Rng(s: 42)
    for _ in 0..<24 {
        ctx.setFillColor(CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 0.12))
        let r = CGFloat(80 + rng.unit() * 300) * scale
        ctx.fillEllipse(in: CGRect(x: CGFloat(rng.unit()) * W, y: CGFloat(rng.unit()) * H, width: r, height: r))
    }
    var trng = Rng(s: UInt64(1000 + variant * 7919))
    func window(_ rect: CGRect, dark: Bool, font: String, size: CGFloat, lineGap: CGFloat) {
        ctx.setFillColor(dark ? CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1) : CGColor(red: 0.98, green: 0.98, blue: 0.97, alpha: 1))
        ctx.fill(rect)
        ctx.setFillColor(CGColor(red: 0.85, green: 0.85, blue: 0.86, alpha: 1))
        ctx.fill(CGRect(x: rect.minX, y: rect.maxY - 28 * scale, width: rect.width, height: 28 * scale))
        for (i, c) in [CGColor(red: 1, green: 0.37, blue: 0.34, alpha: 1), CGColor(red: 1, green: 0.74, blue: 0.18, alpha: 1),
                       CGColor(red: 0.16, green: 0.79, blue: 0.25, alpha: 1)].enumerated() {
            ctx.setFillColor(c)
            ctx.fillEllipse(in: CGRect(x: rect.minX + (10 + CGFloat(i) * 20) * scale, y: rect.maxY - 20 * scale, width: 12 * scale, height: 12 * scale))
        }
        let ctFont = CTFontCreateWithName(font as CFString, size * scale, nil)
        var y = rect.maxY - 28 * scale - (size + lineGap) * scale
        while y > rect.minY + 4 * scale {
            var line = ""
            let indent = Int(trng.next() % 4)
            line += String(repeating: "    ", count: indent)
            let n = 3 + Int(trng.next() % 9)
            for _ in 0..<n { line += words[Int(trng.next() % UInt64(words.count))] + " " }
            let color: CGColor = dark
                ? [CGColor(red: 0.8, green: 0.8, blue: 0.82, alpha: 1), CGColor(red: 0.99, green: 0.46, blue: 0.62, alpha: 1),
                   CGColor(red: 0.42, green: 0.75, blue: 0.99, alpha: 1), CGColor(red: 0.63, green: 0.9, blue: 0.5, alpha: 1)][Int(trng.next() % 4)]
                : CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
            let attrs = [kCTFontAttributeName: ctFont, kCTForegroundColorAttributeName: color] as CFDictionary
            let astr = CFAttributedStringCreate(nil, line as CFString, attrs)!
            let ctLine = CTLineCreateWithAttributedString(astr)
            ctx.textPosition = CGPoint(x: rect.minX + 12 * scale, y: y)
            ctx.saveGState()
            ctx.clip(to: rect)
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
            y -= (size + lineGap) * scale
        }
    }
    let dx = CGFloat(variant % 3) * 40 * scale, dy = CGFloat(variant % 2) * 30 * scale
    window(CGRect(x: 60 * scale + dx, y: 120 * scale + dy, width: 1000 * scale, height: 820 * scale), dark: true, font: "Menlo", size: 13, lineGap: 4)
    window(CGRect(x: 1000 * scale - dx, y: 200 * scale, width: 860 * scale, height: 700 * scale), dark: false, font: "Helvetica", size: 14, lineGap: 6)
    // Dock and menu bar.
    ctx.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.92, alpha: 0.85))
    ctx.fill(CGRect(x: 0, y: H - 30 * scale, width: W, height: 30 * scale))
    ctx.fill(CGRect(x: W * 0.25, y: 8 * scale, width: W * 0.5, height: 70 * scale))
    var irng = Rng(s: 7)
    for i in 0..<16 {
        ctx.setFillColor(CGColor(red: irng.unit(), green: irng.unit(), blue: irng.unit(), alpha: 1))
        ctx.fill(CGRect(x: W * 0.25 + (12 + CGFloat(i) * 60) * scale, y: 16 * scale, width: 52 * scale, height: 52 * scale))
    }
}

func makePixelBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                  kCVPixelBufferCGBitmapContextCompatibilityKey: true]
    let st = CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    precondition(st == kCVReturnSuccess, "CVPixelBufferCreate \(st)")
    return pb!
}

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
