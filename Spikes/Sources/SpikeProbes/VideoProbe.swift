import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import VideoToolbox

// The recovery and zero-copy seams assume things about VideoToolbox:
//  - the encoder supports LTR (per-frame ack tokens + ForceLTRRefresh) in low-latency mode,
//  - a refresh frame is a P-frame (not an IDR) and decodes correctly after losing frames,
//  - the decoder does NOT reliably flag frames whose references were lost (so DecodabilityTracker is needed),
//  - encoder output is one contiguous block (EncodedFrame storage can be retained, not copied),
//  - the decoder accepts a CMBlockBuffer over pool memory and returns it via a custom free callback.

private final class Collector: @unchecked Sendable {
    struct Out { var pts: Int64; var status: OSStatus; var data: [UInt8]; var isSync: Bool; var ltrToken: Int?; var contiguous: Bool; var format: CMFormatDescription? }
    let lock = Mutex<[Out]>([])
}

private final class DecodeLog: @unchecked Sendable {
    struct Out { var pts: Int64; var status: OSStatus; var hash: UInt64? }
    let lock = Mutex<[Out]>([])
}

private let poolFrees = Atomic<Int>(0)

private func fillPattern(_ pb: CVPixelBuffer, frame: Int) {
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    for plane in 0..<max(1, CVPixelBufferGetPlaneCount(pb)) {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane) else { continue }
        let h = CVPixelBufferGetHeightOfPlane(pb, plane), w = CVPixelBufferGetWidthOfPlane(pb, plane)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
        let p = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let row = p + y * bpr
            if plane == 0 {
                for x in 0..<w { row[x] = UInt8(truncatingIfNeeded: (x &+ frame &* 6) ^ (y &+ frame &* 3) &+ ((x / 64 + y / 64 + frame / 8) & 1) &* 90) }
            } else {
                for x in 0..<(w * 2) { row[x] = UInt8(truncatingIfNeeded: 128 &+ ((x / 32 + frame) & 15)) }
            }
        }
    }
}

private func lumaHash(_ pb: CVPixelBuffer) -> UInt64 {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return 0 }
    let h = CVPixelBufferGetHeightOfPlane(pb, 0), w = CVPixelBufferGetWidthOfPlane(pb, 0), bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    let p = base.assumingMemoryBound(to: UInt8.self)
    for y in stride(from: 0, to: h, by: 1) {
        let row = p + y * bpr
        for x in stride(from: 0, to: w, by: 1) { hash = (hash ^ UInt64(row[x])) &* 0x100_0000_01b3 }
    }
    return hash
}

private func codecName(_ c: CMVideoCodecType) -> String { c == kCMVideoCodecType_H264 ? "H.264" : "HEVC" }

/// Encodes `frames` frames; at `refreshAt` it requests ForceLTRRefresh with every token acked so far.
/// LTR tokens are "acked" one frame after they are produced, but only for frames before `lossStart`.
private func encode(codec: CMVideoCodecType, frames: Int, lossStart: Int, refreshAt: Int?, rep: inout Report) -> [Collector.Out]? {
    let w: Int32 = 1920, h: Int32 = 1080
    let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
                                 kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
    let srcAttrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                     kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                                     kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    var session: VTCompressionSession?
    let st = VTCompressionSessionCreate(allocator: nil, width: w, height: h, codecType: codec, encoderSpecification: spec as CFDictionary,
                                        imageBufferAttributes: srcAttrs as CFDictionary, compressedDataAllocator: nil,
                                        outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    guard st == noErr, let session else { rep.add("\(codecName(codec)): low-latency HW encoder create failed: \(st)"); return nil }
    defer { VTCompressionSessionInvalidate(session) }

    var supported: CFDictionary?
    VTSessionCopySupportedPropertyDictionary(session, supportedPropertyDictionaryOut: &supported)
    let sup = (supported as? [String: Any]) ?? [:]
    let props: [(String, CFString, CFTypeRef)] = [
        ("RealTime", kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
        ("AllowFrameReordering=false", kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
        ("AverageBitRate=20M", kVTCompressionPropertyKey_AverageBitRate, 20_000_000 as CFNumber),
        ("ExpectedFrameRate=60", kVTCompressionPropertyKey_ExpectedFrameRate, 60 as CFNumber),
        ("MaxKeyFrameInterval=100000", kVTCompressionPropertyKey_MaxKeyFrameInterval, 100_000 as CFNumber),
        ("EnableLTR", kVTCompressionPropertyKey_EnableLTR, kCFBooleanTrue),
    ]
    var statuses = [String]()
    for (name, key, value) in props {
        let s = VTSessionSetProperty(session, key: key, value: value)
        statuses.append("\(name)=\(s == noErr ? "ok" : String(s))")
    }
    rep.add("\(codecName(codec)) low-latency HW encoder: EnableLTR listed in supported properties: \(sup[kVTCompressionPropertyKey_EnableLTR as String] != nil); set: \(statuses.joined(separator: " "))")
    VTCompressionSessionPrepareToEncodeFrames(session)

    guard let pool = VTCompressionSessionGetPixelBufferPool(session) else { rep.add("no pixel buffer pool"); return nil }
    let out = Collector()
    var pendingAcks = [Int]()
    var acked = [Int]()
    for i in 0..<frames {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        fillPattern(pb!, frame: i)
        var opts: [CFString: Any] = [:]
        if !pendingAcks.isEmpty { opts[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = pendingAcks; acked += pendingAcks; pendingAcks = [] }
        if i == refreshAt { opts[kVTEncodeFrameOptionKey_ForceLTRRefresh] = true }
        let pts = CMTime(value: Int64(i), timescale: 60)
        let s = VTCompressionSessionEncodeFrame(session, imageBuffer: pb!, presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: 60),
                                                frameProperties: opts.isEmpty ? nil : opts as CFDictionary, infoFlagsOut: nil) { status, _, sb in
            var o = Collector.Out(pts: Int64(i), status: status, data: [], isSync: false, ltrToken: nil, contiguous: false, format: nil)
            if let sb, let bb = CMSampleBufferGetDataBuffer(sb) {
                let len = CMBlockBufferGetDataLength(bb)
                o.data = [UInt8](repeating: 0, count: len)
                o.data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
                o.contiguous = CMBlockBufferIsRangeContiguous(bb, atOffset: 0, length: 0)
                o.format = CMSampleBufferGetFormatDescription(sb)
                if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]], let a = atts.first {
                    o.isSync = !((a[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
                    o.ltrToken = (a[kVTSampleAttachmentKey_RequireLTRAcknowledgementToken] as? NSNumber)?.intValue
                } else { o.isSync = true }
            }
            out.lock.withLock { $0.append(o) }
        }
        if s != noErr { rep.add("encode frame \(i) failed: \(s)"); return nil }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: pts)
        // The receiver acks LTR frames it decoded; frames in [lossStart, refreshAt) never arrive.
        if let t = out.lock.withLock({ $0.last?.ltrToken }), i < lossStart { pendingAcks.append(t) }
    }
    return out.lock.withLock { $0 }
}

/// Feeds the chosen frames to a fresh decoder. Each sample's bytes live in "pool" memory wrapped with a
/// custom block source, so the pool learns when VideoToolbox is done with them.
private func decode(_ frames: [Collector.Out], feed: [Int]) -> (log: [DecodeLog.Out], frees: Int, fed: Int) {
    guard let fd = frames.first?.format else { return ([], 0, 0) }
    var ds: VTDecompressionSession?
    guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil, imageBufferAttributes: nil,
                                       outputCallback: nil, decompressionSessionOut: &ds) == noErr, let ds else { return ([], 0, 0) }
    let log = DecodeLog()
    let freesBefore = poolFrees.load(ordering: .relaxed)
    for idx in feed {
        let f = frames[idx]
        autoreleasepool {
            let slab = UnsafeMutableRawPointer.allocate(byteCount: f.data.count, alignment: 64)
            f.data.withUnsafeBytes { slab.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            var source = CMBlockBufferCustomBlockSource(version: 0, AllocateBlock: nil, FreeBlock: { _, block, _ in
                block.deallocate()
                poolFrees.add(1, ordering: .relaxed)
            }, refCon: nil)
            var bb: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: slab, blockLength: f.data.count, blockAllocator: kCFAllocatorNull,
                                               customBlockSource: &source, offsetToData: 0, dataLength: f.data.count, flags: 0, blockBufferOut: &bb)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: CMTime(value: f.pts, timescale: 60), decodeTimeStamp: .invalid)
            var size = f.data.count
            var sb: CMSampleBuffer?
            CMSampleBufferCreateReady(allocator: nil, dataBuffer: bb, formatDescription: fd, sampleCount: 1, sampleTimingEntryCount: 1,
                                      sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
            let pts = f.pts
            let s = VTDecompressionSessionDecodeFrame(ds, sampleBuffer: sb!, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { status, _, image, _, _ in
                log.lock.withLock { $0.append(DecodeLog.Out(pts: pts, status: status, hash: image.map(lumaHash))) }
            }
            if s != noErr { log.lock.withLock { $0.append(DecodeLog.Out(pts: pts, status: s, hash: nil)) } }
        }
    }
    VTDecompressionSessionWaitForAsynchronousFrames(ds)
    VTDecompressionSessionInvalidate(ds)
    let frees = poolFrees.load(ordering: .relaxed) - freesBefore
    return (log.lock.withLock { $0.sorted { $0.pts < $1.pts } }, frees, feed.count)
}

public func videoProbe() -> Report {
    var rep = Report("VideoToolbox — LTR recovery, decoder behaviour on loss, zero-copy seams")
    let frames = 60, lossStart = 30, lossEnd = 36  // frames 30..35 lost; refresh requested at 36
    for codec in [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC] {
        let name = codecName(codec)
        guard let enc = encode(codec: codec, frames: frames, lossStart: lossStart, refreshAt: lossEnd, rep: &rep) else { continue }
        let ltrFrames = enc.filter { $0.ltrToken != nil }.map { Int($0.pts) }
        let syncFrames = enc.filter(\.isSync).map { Int($0.pts) }
        let sizes = enc.map(\.data.count)
        let pAvg = sizes.enumerated().filter { !enc[$0.offset].isSync && $0.offset != lossEnd }.map(\.element).reduce(0, +) / max(1, frames - syncFrames.count - 1)
        rep.add("\(name): sync frames \(syncFrames); LTR-token frames \(ltrFrames.count) (\(ltrFrames.prefix(12).map(String.init).joined(separator: ","))…)")
        rep.add("\(name): sizes — IDR \(sizes[0]) B, refresh frame \(lossEnd) \(sizes[lossEnd]) B (sync=\(enc[lossEnd].isSync)), mean P \(pAvg) B; all outputs contiguous: \(enc.allSatisfy(\.contiguous))")

        let full = decode(enc, feed: Array(0..<frames))
        let recovered = decode(enc, feed: Array(0..<lossStart) + Array(lossEnd..<frames))
        let noRefresh = decode(enc, feed: Array(0..<lossStart) + Array((lossStart + 2)..<lossEnd))  // skip 30,31; feed 32..35
        let fullHash = Dictionary(uniqueKeysWithValues: full.log.map { ($0.pts, $0.hash) })
        let recErrors = recovered.log.filter { $0.status != noErr }.count
        let recMatch = recovered.log.filter { $0.pts >= Int64(lossEnd) }.allSatisfy { $0.hash != nil && $0.hash == fullHash[$0.pts] ?? nil }
        rep.add("\(name): full decode errors \(full.log.filter { $0.status != noErr }.count)/\(full.fed)")
        rep.add("\(name): lose 30–35, ForceLTRRefresh at 36 → decode errors \(recErrors); frames 36–59 bit-identical to full decode: \(recMatch)")
        let nrStatuses = noRefresh.log.filter { $0.pts >= Int64(lossStart) }.map { "\($0.pts):\($0.status)" }
        let nrCorrupt = noRefresh.log.filter { $0.pts >= Int64(lossStart) }.filter { $0.hash != fullHash[$0.pts] ?? nil }.count
        rep.add("\(name): lose 30–31, no refresh, feed 32–35 → statuses [\(nrStatuses.joined(separator: " "))], \(nrCorrupt)/4 outputs differ from truth")
        rep.add("\(name): pool free callbacks \(recovered.frees)/\(recovered.fed) after decode (custom CMBlockBufferCustomBlockSource)")
    }
    return rep
}
