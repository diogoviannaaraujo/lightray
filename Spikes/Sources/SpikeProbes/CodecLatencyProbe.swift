import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Accelerate
import Synchronization
import VideoToolbox

// H.264 vs HEVC in the configuration Lightray would use (hardware, low-latency rate control,
// RealTime, no frame reordering, LTR on): per-frame encode and decode latency at a real-time
// frame pace, frame sizes, and luma PSNR at equal / reduced bitrate.
// Content: a real photo (macOS's default aerial wallpaper) mirror-tiled and panned horizontally.

/// NV12 (video range, BT.709) canvas twice as wide as the output, right half mirrored, so a
/// W×H window can pan across it at native resolution.
struct PanCanvas {
    let width: Int, height: Int  // output size; canvas is 2·width wide
    var y: [UInt8]
    var uv: [UInt8]

    init?(photo path: String, width W: Int, height H: Int) {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        let bgra = ctx.data!.assumingMemoryBound(to: UInt8.self)
        width = W; height = H
        let CW = 2 * W
        y = [UInt8](repeating: 0, count: CW * H)
        uv = [UInt8](repeating: 128, count: CW * (H / 2))
        @inline(__always) func clamp(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        for row in 0..<H {
            for x in 0..<W {
                let p = bgra + row * W * 4 + x * 4
                let b = Double(p[0]), g = Double(p[1]), r = Double(p[2])
                let yy = clamp(16 + (46.559 * r + 156.629 * g + 15.812 * b) / 255)
                y[row * CW + x] = yy
                y[row * CW + (CW - 1 - x)] = yy
            }
        }
        for row in stride(from: 0, to: H, by: 2) {
            for x in stride(from: 0, to: W, by: 2) {
                var r = 0.0, g = 0.0, b = 0.0
                for (dy, dx) in [(0, 0), (0, 1), (1, 0), (1, 1)] {
                    let p = bgra + (row + dy) * W * 4 + (x + dx) * 4
                    b += Double(p[0]); g += Double(p[1]); r += Double(p[2])
                }
                r /= 4; g /= 4; b /= 4
                let cb = clamp(128 + (-25.664 * r - 86.336 * g + 112 * b) / 255)
                let cr = clamp(128 + (112 * r - 101.730 * g - 10.270 * b) / 255)
                let o = (row / 2) * CW
                uv[o + x] = cb; uv[o + x + 1] = cr
                let m = CW - 2 - x  // mirrored chroma pair
                uv[o + m] = cb; uv[o + m + 1] = cr
            }
        }
    }

    func fill(_ pb: CVPixelBuffer, offset: Int) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let CW = 2 * width
        let o = (offset & ~1) % CW
        let first = min(width, CW - o)  // wrap: [image | mirror] repeats with period 2W
        for (plane, rows, src) in [(0, height, y), (1, height / 2, uv)] {
            let dst = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
            src.withUnsafeBufferPointer { s in
                for r in 0..<rows {
                    (dst + r * bpr).update(from: s.baseAddress! + r * CW + o, count: first)
                    if first < width { (dst + r * bpr + first).update(from: s.baseAddress! + r * CW, count: width - first) }
                }
            }
        }
    }
}

/// Zoom-and-drift camera over the (unmirrored) photo, resampled every frame with vImage, so
/// motion is sub-pixel and non-translational: much harder to predict than an integer pan.
struct ZoomCanvas {
    let base: PanCanvas  // image occupies columns [0, cw) of each 2·cw-wide row
    let cw: Int, ch: Int, width: Int, height: Int

    init?(photo: String, width W: Int, height H: Int, margin: Double = 1.3) {
        cw = Int(Double(W) * margin) & ~1; ch = Int(Double(H) * margin) & ~1
        guard let b = PanCanvas(photo: photo, width: cw, height: ch) else { return nil }
        base = b; width = W; height = H
    }

    func render(_ i: Int, _ pb: CVPixelBuffer) {
        let z = 1.15 + 0.15 * sin(2 * .pi * Double(i) / 120)  // crop = output × z, then downscale
        let cropW = min(cw, Int(Double(width) * z)) & ~1, cropH = min(ch, Int(Double(height) * z)) & ~1
        let cx = Int(Double(cw - cropW) * (0.5 + 0.5 * sin(2 * .pi * Double(i) / 97))) & ~1
        let cy = Int(Double(ch - cropH) * (0.5 + 0.5 * cos(2 * .pi * Double(i) / 131))) & ~1
        let CW = 2 * cw
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        base.y.withUnsafeBufferPointer { y in
            var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: y.baseAddress! + cy * CW + cx),
                                    height: vImagePixelCount(cropH), width: vImagePixelCount(cropW), rowBytes: CW)
            var dst = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(pb, 0), height: vImagePixelCount(height),
                                    width: vImagePixelCount(width), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pb, 0))
            _ = vImageScale_Planar8(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
        }
        base.uv.withUnsafeBufferPointer { uv in
            var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: uv.baseAddress! + (cy / 2) * CW + cx),
                                    height: vImagePixelCount(cropH / 2), width: vImagePixelCount(cropW / 2), rowBytes: CW)
            var dst = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(pb, 1), height: vImagePixelCount(height / 2),
                                    width: vImagePixelCount(width / 2), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pb, 1))
            _ = vImageScale_CbCr8(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
        }
    }
}

func lumaPlane(_ pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0), bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    let p = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
    var out = [UInt8](repeating: 0, count: w * h)
    for r in 0..<h { out.withUnsafeMutableBufferPointer { ($0.baseAddress! + r * w).update(from: p + r * bpr, count: w) } }
    return out
}

func lumaPSNR(_ decoded: CVPixelBuffer, reference: [UInt8]) -> Double {
    let d = lumaPlane(decoded)
    var sse: UInt64 = 0
    for k in 0..<min(d.count, reference.count) { let e = Int(d[k]) - Int(reference[k]); sse &+= UInt64(e * e) }
    let mse = Double(sse) / Double(reference.count)
    return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
}

/// Lock-guarded storage shared with VideoToolbox callback threads (holds non-Sendable CV/CM types).
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func withLock<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
}

struct CodecRun {
    var name: String
    var encodeMs: [Double] = []
    var decodeMs: [Double] = []
    var sizes: [Int] = []
    var psnr: [Double] = []
    var dropped = 0
    var error: String?
}

private func waitUntil(_ t: UInt64) { let now = nowNs(); if t > now { usleep(UInt32((t - now) / 1000)) } }

func runCodec(_ codec: CMVideoCodecType, width: Int, height: Int, bitrate: Int, fps: Int, frames: Int,
              prioritizeSpeed: Bool = false, ltr: Bool = true, capFactor: Double? = nil, cbr: Bool = false, label: String,
              render: (Int, CVPixelBuffer) -> Void) -> CodecRun {
    var run = CodecRun(name: label)
    let W = Int32(width), H = Int32(height)
    let keep = { (i: Int) in i >= 30 && i % 10 == 0 }
    var refs = [Int: [UInt8]]()
    let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
                                 kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
    let srcAttrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                     kCVPixelBufferWidthKey: W, kCVPixelBufferHeightKey: H,
                                     kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    var session: VTCompressionSession?
    let st = VTCompressionSessionCreate(allocator: nil, width: W, height: H, codecType: codec, encoderSpecification: spec as CFDictionary,
                                        imageBufferAttributes: srcAttrs as CFDictionary, compressedDataAllocator: nil,
                                        outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    guard st == noErr, let session else { run.error = "encoder create \(st)"; return run }
    defer { VTCompressionSessionInvalidate(session) }
    var props: [(CFString, CFTypeRef)] = [
        (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
        (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
        (cbr ? kVTCompressionPropertyKey_ConstantBitRate : kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber),
        (kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber),
        (kVTCompressionPropertyKey_MaxKeyFrameInterval, 100_000 as CFNumber),
    ]
    if ltr { props.append((kVTCompressionPropertyKey_EnableLTR, kCFBooleanTrue)) }
    if prioritizeSpeed { props.append((kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)) }
    if let f = capFactor {
        // Hard cap: at most f × the per-frame budget within any single frame interval.
        let bytes = Double(bitrate) / 8 / Double(fps) * f
        props.append((kVTCompressionPropertyKey_DataRateLimits, [bytes, 1.0 / Double(fps)] as CFArray))
    }
    for (k, v) in props {
        let s = VTSessionSetProperty(session, key: k, value: v)
        if s != noErr { run.error = "set \(k) → \(s)"; return run }
    }
    VTCompressionSessionPrepareToEncodeFrames(session)
    guard let pool = VTCompressionSessionGetPixelBufferPool(session) else { run.error = "no pool"; return run }

    struct Encoded { var data: Data; var fd: CMFormatDescription?; var outNs: UInt64 }
    let outs = Box([Int: Encoded]())
    var submit = [UInt64](repeating: 0, count: frames)
    let interval = UInt64(1_000_000_000 / fps)
    var next = nowNs() + interval
    for i in 0..<frames {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        render(i, pb!)
        if keep(i) { refs[i] = lumaPlane(pb!) }
        waitUntil(next)
        next += interval
        submit[i] = nowNs()
        let s = VTCompressionSessionEncodeFrame(session, imageBuffer: pb!, presentationTimeStamp: CMTime(value: Int64(i), timescale: Int32(fps)),
                                                duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { status, _, sb in
            let t = nowNs()
            guard status == noErr, let sb, let bb = CMSampleBufferGetDataBuffer(sb) else { return }
            var data = Data(count: CMBlockBufferGetDataLength(bb))
            data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            outs.withLock { $0[i] = Encoded(data: data, fd: CMSampleBufferGetFormatDescription(sb), outNs: t) }
        }
        if s != noErr { run.error = "encode \(i) → \(s)"; return run }
    }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    let enc = outs.withLock { $0 }
    let emitted = enc.keys.sorted()  // under a tight budget the encoder drops frames
    guard let first = emitted.first, let fd = enc[first]?.fd else { run.error = "0/\(frames) frames out"; return run }
    run.dropped = frames - emitted.count
    run.encodeMs = emitted.map { Double(enc[$0]!.outNs - submit[$0]) / 1e6 }
    run.sizes = emitted.map { enc[$0]!.data.count }

    // Decode at the same real-time pace, keeping a few outputs for PSNR afterwards.
    var ds: VTDecompressionSession?
    let outAttrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil,
                                       imageBufferAttributes: outAttrs as CFDictionary, outputCallback: nil,
                                       decompressionSessionOut: &ds) == noErr, let ds else { run.error = "decoder create"; return run }
    defer { VTDecompressionSessionInvalidate(ds) }
    let decOut = Box([Int: (UInt64, CVPixelBuffer?)]())
    var decSubmit = [UInt64](repeating: 0, count: frames)
    next = nowNs() + interval
    for i in emitted {
        let e = enc[i]!
        var bb: CMBlockBuffer?
        let len = e.data.count
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: len, blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: len, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bb)
        e.data.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb!, offsetIntoDestination: 0, dataLength: len) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(i), timescale: Int32(fps)), decodeTimeStamp: .invalid)
        var size = len
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: bb, formatDescription: fd, sampleCount: 1, sampleTimingEntryCount: 1,
                                  sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
        let keepOut = keep(i)
        waitUntil(next)
        next += interval
        decSubmit[i] = nowNs()
        VTDecompressionSessionDecodeFrame(ds, sampleBuffer: sb!, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { status, _, image, _, _ in
            let t = nowNs()
            decOut.withLock { $0[i] = (t, status == noErr && keepOut ? image : nil) }
        }
    }
    VTDecompressionSessionWaitForAsynchronousFrames(ds)
    let dec = decOut.withLock { $0 }
    run.decodeMs = emitted.compactMap { i in dec[i].map { Double($0.0 - decSubmit[i]) / 1e6 } }
    run.psnr = dec.sorted { $0.key < $1.key }.compactMap { i, v in
        guard let img = v.1, let ref = refs[i] else { return nil }
        return lumaPSNR(img, reference: ref)
    }
    return run
}

public func codecLatencyProbe(frames: Int = 180) -> Report {
    var rep = Report("H.264 vs HEVC — hardware, low-latency RC, real-time pace (ms from submit to output)")
    let photo = "/System/Library/Wallpapers/.default/DefaultAerial.jpg"
    let h264 = kCMVideoCodecType_H264, hevc = kCMVideoCodecType_HEVC
    struct Run { var codec: CMVideoCodecType; var mbps: Int; var fps = 60; var ltr = true; var cap: Double? = nil; var cbr = false }
    struct Case { var title: String; var w: Int; var h: Int; var pan: Int; var zoom = false; var runs: [Run] }
    let sweepZoom = [2, 4, 8, 16].flatMap { [Run(codec: h264, mbps: $0), Run(codec: hevc, mbps: $0)] }
    let sweep1080 = [3, 6, 12].flatMap { [Run(codec: h264, mbps: $0), Run(codec: hevc, mbps: $0)] }
    let sweep2160 = [10, 20, 40].flatMap { [Run(codec: h264, mbps: $0), Run(codec: hevc, mbps: $0)] }
    let cases = [
        Case(title: "1080p60, zoom + drift camera (sub-pixel motion) — bitrate sweep", w: 1920, h: 1080, pan: 0, zoom: true, runs: sweepZoom),
        Case(title: "1080p60, zoom + drift — frame-size control at 4 Mbps", w: 1920, h: 1080, pan: 0, zoom: true, runs: [
            Run(codec: h264, mbps: 4, cap: 2), Run(codec: hevc, mbps: 4, cap: 2),
            Run(codec: h264, mbps: 4, cap: 1.5), Run(codec: hevc, mbps: 4, cap: 1.5),
            Run(codec: h264, mbps: 4, cbr: true), Run(codec: hevc, mbps: 4, cbr: true)]),
        Case(title: "1080p, fast pan 16 px/frame — bitrate sweep", w: 1920, h: 1080, pan: 16, runs: sweep1080),
        Case(title: "2160p, fast pan 32 px/frame — bitrate sweep", w: 3840, h: 2160, pan: 32, runs: sweep2160),
        Case(title: "2160p latency variants (40 Mbps)", w: 3840, h: 2160, pan: 32, runs: [
            Run(codec: h264, mbps: 40, ltr: false), Run(codec: hevc, mbps: 40, ltr: false),
            Run(codec: h264, mbps: 40, fps: 30), Run(codec: hevc, mbps: 40, fps: 30),
            Run(codec: h264, mbps: 40, fps: 120), Run(codec: hevc, mbps: 40, fps: 120)]),
        Case(title: "1080p120 (12 Mbps)", w: 1920, h: 1080, pan: 8, runs: [Run(codec: h264, mbps: 12, fps: 120), Run(codec: hevc, mbps: 12, fps: 120)]),
    ]
    let fmt = { (d: Distribution) in String(format: "%5.1f %5.1f %5.1f", d.p(0.5), d.p(0.99), d.max) }
    rep.add("content: \(photo) (3840×2160 photo), mirror-tiled, horizontal pan with wrap-around; \(frames) frames per run")
    let only = ProcessInfo.processInfo.environment["CODEC_CASES"]
    for c in cases where only == nil || c.title.contains(only!) {
        rep.add("[\(c.title)]")
        rep.add("  config                     encode p50/p99/max  decode p50/p99/max  used Mbps  IDR KB  max P KB  Y-PSNR dB  dropped")
        let pan = c.zoom ? nil : PanCanvas(photo: photo, width: c.w, height: c.h)
        let zoom = c.zoom ? ZoomCanvas(photo: photo, width: c.w, height: c.h) : nil
        guard pan != nil || zoom != nil else { rep.add("cannot load \(photo)"); return rep }
        for r in c.runs {
            let label = "\(r.codec == h264 ? "H.264" : "HEVC ") \(r.mbps) Mbps \(r.fps) fps\(r.ltr ? "" : " noLTR")"
                + (r.cap.map { String(format: " cap%.1fx", $0) } ?? "") + (r.cbr ? " CBR" : "")
            let run = runCodec(r.codec, width: c.w, height: c.h, bitrate: r.mbps * 1_000_000, fps: r.fps, frames: frames,
                               ltr: r.ltr, capFactor: r.cap, cbr: r.cbr, label: label) { i, pb in
                if let zoom { zoom.render(i, pb) } else { pan!.fill(pb, offset: i * c.pan) }
            }
            if let e = run.error { rep.add("  \(label): \(e)"); continue }
            let steady = run.sizes.dropFirst(30)
            let usedMbps = Double(steady.reduce(0, +)) * 8 * Double(r.fps) / Double(steady.count) / 1e6
            rep.add(String(format: "  %-25@  %@   %@   %8.1f  %6.1f  %8.1f  %9.2f  %7d",
                           label as NSString, fmt(Distribution(run.encodeMs)), fmt(Distribution(run.decodeMs)), usedMbps,
                           Double(run.sizes[0]) / 1000, Double(run.sizes.dropFirst().max() ?? 0) / 1000,
                           run.psnr.reduce(0, +) / Double(max(1, run.psnr.count)), run.dropped))
            if ProcessInfo.processInfo.environment["CODEC_SIZES"] != nil {
                let budget = Double(r.mbps) * 1e6 / 8 / Double(r.fps) / 1000
                let ps = Distribution(run.sizes.dropFirst().map { Double($0) / 1000 })
                let big = run.sizes.enumerated().dropFirst().sorted { $0.element > $1.element }.prefix(5).map { "#\($0.offset):\($0.element / 1000)KB" }
                rep.add(String(format: "      P-frame KB: budget %.1f  p50 %.1f  p90 %.1f  p99 %.1f  max %.1f; largest: ", budget, ps.p(0.5), ps.p(0.9), ps.p(0.99), ps.max)
                        + big.joined(separator: " "))
            }
        }
    }
    rep.add("PrioritizeEncodingSpeedOverQuality: rejected (-12900) by both low-latency encoders")
    return rep
}
