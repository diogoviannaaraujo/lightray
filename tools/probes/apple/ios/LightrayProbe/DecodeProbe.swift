// VideoToolbox measurements on the iPad: what a client pays to (re)build its decoder, how long a
// first IDR and steady frames take to decode, which HEVC formats decode in hardware, and what
// iPadOS does to a decoder session across a background/foreground cycle.
import CoreMedia
import CoreVideo
import Foundation
import UIKit
import VideoToolbox

final class DecodeProbe: @unchecked Sendable {
    static let shared = DecodeProbe()
    private let queue = DispatchQueue(label: "lightray.probe.decode", qos: .userInitiated)

    // Kept alive for the check after the next foreground.
    private var keptDecoder: VTDecompressionSession?
    private var keptEncoder: VTCompressionSession?
    private var keptIDR: CMSampleBuffer?
    private var keptFrame: CVPixelBuffer?
    private var decodersCreated = 0

    /// The 1080p stream, for the picture-in-picture keep-alive.
    private(set) var pipSamples: [CMSampleBuffer] = []

    func run(completion: @escaping () -> Void) {
        queue.async {
            self.runEncodeDecode()
            self.runBundledSamples()
            DispatchQueue.main.async(execute: completion)
        }
    }

    // MARK: Encode + decode sweep

    private func runEncodeDecode() {
        let native = nativeLandscapeSize()
        var configs: [(String, Int, Int, Int)] = [("1080p", 1920, 1080, 20_000_000), ("1440p", 2560, 1440, 20_000_000)]
        if native.0 > 0 { configs.append(("native \(native.0)x\(native.1)", native.0, native.1, 40_000_000)) }
        configs.append(("2160p", 3840, 2160, 40_000_000))
        for (name, w, h, rate) in configs {
            autoreleasepool { encodeDecode(name: name, w: w, h: h, bitrate: rate) }
        }
    }

    private func encodeDecode(name: String, w: Int, h: Int, bitrate: Int) {
        let a = makePixelBuffer(w, h), b = makePixelBuffer(w, h)
        drawDesktop(into: a, variant: 0)
        drawDesktop(into: b, variant: 1)
        let t0 = monoNs()
        guard let (enc, lowLatency) = makeEncoder(w: w, h: h, bitrate: bitrate) else {
            Report.line("ENCODE \(name) failed to create an HEVC encoder")
            return
        }
        let createMs = Double(monoNs() - t0) / 1e6
        var samples: [CMSampleBuffer] = []
        var lat: [Double] = []
        var firstMs = 0.0
        for i in 0..<90 {
            guard let (sb, ms) = encode(enc, i < 45 ? a : b, index: i, forceKey: i == 0) else { break }
            samples.append(sb)
            if i == 0 { firstMs = ms } else { lat.append(ms) }
        }
        guard samples.count == 90 else {
            Report.line("ENCODE \(name) stopped after \(samples.count) frames")
            VTCompressionSessionInvalidate(enc)
            return
        }
        let idrKB = Double(CMSampleBufferGetTotalSampleSize(samples[0])) / 1024
        let changedKB = Double(CMSampleBufferGetTotalSampleSize(samples[45])) / 1024
        Report.line(String(format: "ENCODE %@ low_latency=%@ create_ms=%.1f first_idr_ms=%.1f idr_kb=%.1f p_p50_ms=%.1f p_p99_ms=%.1f changed_screen_p_kb=%.1f",
                           name, lowLatency ? "yes" : "no", createMs, firstMs, idrKB, percentile(lat, 50), percentile(lat, 99), changedKB))

        guard let fmt = CMSampleBufferGetFormatDescription(samples[0]) else { return }
        let cold = decodersCreated == 0
        guard let (dec, decCreate) = makeDecoder(fmt, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) else {
            Report.line("DECODE \(name) failed to create a decoder")
            return
        }
        var creates: [Double] = []
        for _ in 0..<5 {
            if let (d, ms) = makeDecoder(fmt, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
                creates.append(ms)
                VTDecompressionSessionInvalidate(d)
            }
        }
        let (idrStatus, idrMs) = decode(dec, samples[0])
        var pLat: [Double] = []
        var errors = idrStatus == noErr ? 0 : 1
        for sb in samples.dropFirst() {
            let (st, ms) = decode(dec, sb)
            if st != noErr { errors += 1 } else { pLat.append(ms) }
        }
        Report.line(String(format: "DECODE %@ create_ms=%.1f (%@) warm_create_p50_ms=%.1f first_idr_ms=%.1f p_p50_ms=%.2f p_p99_ms=%.2f p_max_ms=%.1f errors=%d",
                           name, decCreate, cold ? "first in process" : "warm", percentile(creates, 50), idrMs, percentile(pLat, 50),
                           percentile(pLat, 99), pLat.max() ?? .nan, errors))
        if name == "1080p" {
            keptDecoder = dec
            keptEncoder = enc
            keptIDR = samples[0]
            keptFrame = a
            pipSamples = samples
            Report.line("DECODE kept the 1080p decoder and encoder for the next foreground")
        } else {
            VTDecompressionSessionInvalidate(dec)
            VTCompressionSessionInvalidate(enc)
        }
    }

    // MARK: After a background/foreground cycle

    func checkAfterForeground() {
        queue.async {
            guard let dec = self.keptDecoder, let idr = self.keptIDR, let fmt = CMSampleBufferGetFormatDescription(idr) else { return }
            let (st, ms) = self.decode(dec, idr)
            var line = String(format: "DECODER_AFTER_BACKGROUND old_session_status=%d old_decode_ms=%.1f", st, ms)
            if let enc = self.keptEncoder, let frame = self.keptFrame {
                let r = self.encode(enc, frame, index: 10_000 + Int(nowMs()), forceKey: true)
                line += String(format: " old_encoder=%@", r == nil ? "failed" : String(format: "ok %.1fms", r!.1))
            }
            VTDecompressionSessionInvalidate(dec)
            if let (fresh, createMs) = self.makeDecoder(fmt, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
                let (st2, ms2) = self.decode(fresh, idr)
                line += String(format: " rebuilt_create_ms=%.1f rebuilt_first_idr_ms=%.1f rebuilt_status=%d", createMs, ms2, st2)
                self.keptDecoder = fresh
            } else {
                line += " rebuild_failed"
                self.keptDecoder = nil
            }
            Report.line(line)
        }
    }

    // MARK: Bundled HEVC samples (Main10, 4:4:4, 4:2:2), made on the Mac by build.sh

    private func runBundledSamples() {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "hevc", subdirectory: nil) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        if urls.isEmpty { Report.line("SAMPLES none bundled (run build.sh with ffmpeg available)"); return }
        let hw = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        for url in urls {
            autoreleasepool {
                guard let data = try? Data(contentsOf: url) else { return }
                let name = url.deletingPathExtension().lastPathComponent
                let aus = accessUnits(annexB(data))
                guard let fmt = formatDescription(aus.first ?? []) else {
                    Report.line("SAMPLE \(name) no parameter sets"); return
                }
                let dims = CMVideoFormatDescriptionGetDimensions(fmt)
                guard let (dec, createMs) = makeDecoder(fmt, pixelFormat: nil) else {
                    Report.line("SAMPLE \(name) \(dims.width)x\(dims.height) decoder_create=failed hevc_hw=\(hw)"); return
                }
                var errors = 0, firstStatus: OSStatus = 0
                var lat: [Double] = []
                var outFormat = "?"
                for (i, au) in aus.enumerated() {
                    guard let sb = sampleBuffer(au, fmt: fmt, index: i) else { errors += 1; continue }
                    let (st, ms, pf) = decodeWithFormat(dec, sb)
                    if i == 0 { firstStatus = st; outFormat = pf }
                    if st != noErr { errors += 1 } else { lat.append(ms) }
                }
                VTDecompressionSessionInvalidate(dec)
                Report.line(String(format: "SAMPLE %@ %dx%d frames=%d create_ms=%.1f first_status=%d errors=%d decode_p50_ms=%.2f output=%@",
                                   name, dims.width, dims.height, aus.count, createMs, firstStatus, errors, percentile(lat, 50), outFormat))
            }
        }
    }

    // MARK: VideoToolbox helpers

    private func nativeLandscapeSize() -> (Int, Int) {
        var size = CGSize.zero
        DispatchQueue.main.sync {
            let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
            size = screen?.nativeBounds.size ?? .zero
        }
        let w = Int(max(size.width, size.height)) & ~1, h = Int(min(size.width, size.height)) & ~1
        return (w, h)
    }

    private func makeEncoder(w: Int, h: Int, bitrate: Int) -> (VTCompressionSession, Bool)? {
        for lowLatency in [true, false] {
            var s: VTCompressionSession?
            let spec = lowLatency ? ([kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary) : nil
            let st = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_HEVC,
                                                encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
            guard st == noErr, let sess = s else { continue }
            VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
            VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
            VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 100_000 as CFNumber)
            VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_EnableLTR, value: kCFBooleanTrue)
            VTCompressionSessionPrepareToEncodeFrames(sess)
            return (sess, lowLatency)
        }
        return nil
    }

    private func encode(_ s: VTCompressionSession, _ pb: CVPixelBuffer, index: Int, forceKey: Bool) -> (CMSampleBuffer, Double)? {
        let sem = DispatchSemaphore(value: 0)
        var out: (CMSampleBuffer, Double)?
        let pts = CMTime(value: CMTimeValue(index), timescale: 60)
        let props: CFDictionary? = forceKey ? ([kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary) : nil
        let t0 = monoNs()
        let st = VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: 60),
                                                 frameProperties: props, infoFlagsOut: nil) { status, _, sb in
            if status == noErr, let sb { out = (sb, Double(monoNs() - t0) / 1e6) }
            sem.signal()
        }
        guard st == noErr else { return nil }
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: pts)
        sem.wait()
        return out
    }

    private func makeDecoder(_ fmt: CMFormatDescription, pixelFormat: OSType?) -> (VTDecompressionSession, Double)? {
        var attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        if let pixelFormat { attrs[kCVPixelBufferPixelFormatTypeKey] = pixelFormat }
        var s: VTDecompressionSession?
        let t0 = monoNs()
        let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil,
                                              imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
        let ms = Double(monoNs() - t0) / 1e6
        guard st == noErr, let sess = s else { return nil }
        decodersCreated += 1
        return (sess, ms)
    }

    private func decode(_ s: VTDecompressionSession, _ sb: CMSampleBuffer) -> (OSStatus, Double) {
        let r = decodeWithFormat(s, sb)
        return (r.0, r.1)
    }

    private func decodeWithFormat(_ s: VTDecompressionSession, _ sb: CMSampleBuffer) -> (OSStatus, Double, String) {
        let sem = DispatchSemaphore(value: 0)
        var status: OSStatus = noErr
        var format = "none"
        let t0 = monoNs()
        var end: UInt64 = 0
        let st = VTDecompressionSessionDecodeFrame(s, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { st, _, image, _, _ in
            status = st
            if let image {
                let f = CVPixelBufferGetPixelFormatType(image)
                format = String(format: "%c%c%c%c", (f >> 24) & 0xff, (f >> 16) & 0xff, (f >> 8) & 0xff, f & 0xff)
            }
            end = monoNs()
            sem.signal()
        }
        if st != noErr { return (st, Double(monoNs() - t0) / 1e6, format) }
        sem.wait()
        return (status, Double(end - t0) / 1e6, format)
    }

    // MARK: Annex B parsing for the bundled samples

    private func annexB(_ d: Data) -> [Data] {
        let b = [UInt8](d)
        var starts: [(Int, Int)] = []  // (start code offset, payload offset)
        var i = 0
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                let codeStart = (i > 0 && b[i - 1] == 0) ? i - 1 : i
                starts.append((codeStart, i + 3))
                i += 3
            } else { i += 1 }
        }
        var nals: [Data] = []
        for (k, s) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1].0 : b.count
            if end > s.1 { nals.append(Data(b[s.1..<end])) }
        }
        return nals
    }

    private func nalType(_ n: Data) -> Int { Int((n[n.startIndex] >> 1) & 0x3f) }

    /// Groups NAL units into access units: a VCL NAL with first_slice_segment_in_pic_flag starts a new picture.
    private func accessUnits(_ nals: [Data]) -> [[Data]] {
        var aus: [[Data]] = []
        var current: [Data] = []
        var pending: [Data] = []
        var hasVCL = false
        for n in nals where n.count > 2 {
            let t = nalType(n)
            if t < 32 {
                let first = (n[n.startIndex + 2] & 0x80) != 0
                if first && hasVCL { aus.append(current); current = []; hasVCL = false }
                current += pending; pending = []
                current.append(n); hasVCL = true
            } else if t == 40 {
                current.append(n)
            } else {
                pending.append(n)
            }
        }
        if hasVCL { aus.append(current) }
        return aus
    }

    private func formatDescription(_ au: [Data]) -> CMFormatDescription? {
        let vps = au.first { nalType($0) == 32 }, sps = au.first { nalType($0) == 33 }, pps = au.first { nalType($0) == 34 }
        guard let vps, let sps, let pps else { return nil }
        let sets = [vps, sps, pps]
        var fmt: CMFormatDescription?
        let st = sets[0].withUnsafeBytes { v in sets[1].withUnsafeBytes { s in sets[2].withUnsafeBytes { p in
            let ptrs: [UnsafePointer<UInt8>] = [v.bindMemory(to: UInt8.self).baseAddress!, s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
            let sizes = sets.map(\.count)
            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: 3, parameterSetPointers: ptrs,
                                                                       parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil,
                                                                       formatDescriptionOut: &fmt)
        } } }
        return st == noErr ? fmt : nil
    }

    private func sampleBuffer(_ au: [Data], fmt: CMFormatDescription, index: Int) -> CMSampleBuffer? {
        var payload = Data()
        for n in au where ![32, 33, 34, 35].contains(nalType(n)) {
            var len = UInt32(n.count).bigEndian
            payload.append(Data(bytes: &len, count: 4))
            payload.append(n)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: payload.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: payload.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        _ = payload.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 60),
                                        decodeTimeStamp: .invalid)
        var size = payload.count
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: 1, sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr
        else { return nil }
        return sb
    }
}
