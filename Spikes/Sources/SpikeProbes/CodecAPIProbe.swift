import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// Does every VideoToolbox API the design relies on work for HEVC as well as H.264?
// One scripted low-latency stream per codec (LTR on, acks one frame late):
//   frame 60 ForceKeyFrame · 90 bitrate 8→3 Mbps · 150 bitrate 3→12 Mbps · 180 ForceKeyFrame ·
//   200 ExpectedFrameRate 60→30 (timestamps switch to 30 fps too)
// then: parameter-set extraction + rebuild, a fresh decoder joining at a forced keyframe (resume
// with decoder_lost), 10-bit/HDR in low-latency mode, and a diff of the supported property sets.

private final class Sink: @unchecked Sendable {
    struct Frame { var data: [UInt8]; var fd: CMFormatDescription?; var sync: Bool; var ltr: Bool; var status: OSStatus; var token: Int? = nil }
    private let lock = NSLock()
    private var frames: [Int: Frame] = [:]
    func put(_ i: Int, _ f: Frame) { lock.lock(); frames[i] = f; lock.unlock() }
    var all: [Int: Frame] { lock.lock(); defer { lock.unlock() }; return frames }
}

private func lowLatencyEncoder(_ codec: CMVideoCodecType, _ w: Int, _ h: Int, pixelFormat: OSType) -> (VTCompressionSession?, OSStatus) {
    let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
                                 kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
    let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: pixelFormat, kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                                  kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    var s: VTCompressionSession?
    let st = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: codec, encoderSpecification: spec as CFDictionary,
                                        imageBufferAttributes: attrs as CFDictionary, compressedDataAllocator: nil, outputCallback: nil,
                                        refcon: nil, compressionSessionOut: &s)
    return (s, st)
}

private func set(_ s: VTCompressionSession, _ k: CFString, _ v: CFTypeRef) -> OSStatus { VTSessionSetProperty(s, key: k, value: v) }

/// NAL unit types in a length-prefixed (AVCC/HVCC) sample.
private func nalTypes(_ data: [UInt8], hevc: Bool, lengthSize: Int = 4) -> [Int] {
    var out = [Int](), o = 0
    while o + lengthSize <= data.count {
        var len = 0
        for k in 0..<lengthSize { len = len << 8 | Int(data[o + k]) }
        o += lengthSize
        guard len > 0, o + len <= data.count else { break }
        out.append(hevc ? Int(data[o] >> 1) & 0x3F : Int(data[o]) & 0x1F)
        o += len
    }
    return out
}

private func parameterSets(_ fd: CMFormatDescription, hevc: Bool) -> (sets: [[UInt8]], nalLength: Int32) {
    var count = 0, nalLen: Int32 = 0
    if hevc { CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLen) }
    else { CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLen) }
    var sets = [[UInt8]]()
    for i in 0..<count {
        var p: UnsafePointer<UInt8>?, n = 0
        if hevc { CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &n, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) }
        else { CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &n, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) }
        if let p { sets.append(Array(UnsafeBufferPointer(start: p, count: n))) }
    }
    return (sets, nalLen)
}

/// Receiver side: a format description built only from the parameter-set bytes (as they would arrive on the wire).
private func rebuild(_ sets: [[UInt8]], nalLength: Int32, hevc: Bool) -> (CMFormatDescription?, OSStatus) {
    let flat = sets.flatMap { $0 }
    var offsets = [Int](), acc = 0
    for s in sets { offsets.append(acc); acc += s.count }
    var fd: CMFormatDescription?
    let st: OSStatus = flat.withUnsafeBufferPointer { buf in
        let ptrs = offsets.map { buf.baseAddress! + $0 }
        let sizes = sets.map(\.count)
        return ptrs.withUnsafeBufferPointer { p in
            sizes.withUnsafeBufferPointer { z in
                hevc ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: p.baseAddress!,
                                                                          parameterSetSizes: z.baseAddress!, nalUnitHeaderLength: nalLength, extensions: nil, formatDescriptionOut: &fd)
                     : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: p.baseAddress!,
                                                                          parameterSetSizes: z.baseAddress!, nalUnitHeaderLength: nalLength, formatDescriptionOut: &fd)
            }
        }
    }
    return (fd, st)
}

private func hashLuma(_ pb: CVPixelBuffer) -> UInt64 {
    let y = lumaPlane(pb)
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in y { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
    return h
}

private final class DecodeResults: @unchecked Sendable {
    private let lock = NSLock()
    private var r: [Int: (OSStatus, UInt64?)] = [:]
    func put(_ i: Int, _ v: (OSStatus, UInt64?)) { lock.lock(); r[i] = v; lock.unlock() }
    var all: [Int: (OSStatus, UInt64?)] { lock.lock(); defer { lock.unlock() }; return r }
}

private func decode(_ frames: [Int: Sink.Frame], indices: [Int], using fd: CMFormatDescription, fps: (Int) -> Int32) -> [Int: (OSStatus, UInt64?)] {
    var ds: VTDecompressionSession?
    let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
                                       outputCallback: nil, decompressionSessionOut: &ds) == noErr, let ds else { return [:] }
    defer { VTDecompressionSessionInvalidate(ds) }
    let res = DecodeResults()
    for i in indices {
        guard let f = frames[i], !f.data.isEmpty else { continue }  // skipped by the encoder
        var bb: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: f.data.count, blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: f.data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bb)
        f.data.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb!, offsetIntoDestination: 0, dataLength: f.data.count) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(i), timescale: fps(i)), decodeTimeStamp: .invalid)
        var size = f.data.count
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: bb, formatDescription: fd, sampleCount: 1, sampleTimingEntryCount: 1,
                                  sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
        let s = VTDecompressionSessionDecodeFrame(ds, sampleBuffer: sb!, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            res.put(i, (status, image.map(hashLuma)))
        }
        if s != noErr { res.put(i, (s, nil)) }
    }
    VTDecompressionSessionWaitForAsynchronousFrames(ds)
    return res.all
}

private func scriptedStream(_ codec: CMVideoCodecType, canvas: ZoomCanvas, rep: inout Report) {
    let hevc = codec == kCMVideoCodecType_HEVC
    let name = hevc ? "HEVC " : "H.264"
    let frames = 240
    let (sess, st) = lowLatencyEncoder(codec, canvas.width, canvas.height, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    guard let s = sess else { rep.add("\(name): create failed \(st)"); return }
    defer { VTCompressionSessionInvalidate(s) }
    _ = set(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
    _ = set(s, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
    _ = set(s, kVTCompressionPropertyKey_AverageBitRate, 8_000_000 as CFNumber)
    _ = set(s, kVTCompressionPropertyKey_ExpectedFrameRate, 60 as CFNumber)
    _ = set(s, kVTCompressionPropertyKey_MaxKeyFrameInterval, 100_000 as CFNumber)
    _ = set(s, kVTCompressionPropertyKey_EnableLTR, kCFBooleanTrue)
    VTCompressionSessionPrepareToEncodeFrames(s)
    guard let pool = VTCompressionSessionGetPixelBufferPool(s) else { rep.add("\(name): no pixel buffer pool"); return }
    let sink = Sink()
    let fps = { (i: Int) -> Int32 in i >= 200 ? 30 : 60 }
    let pts = { (i: Int) -> CMTime in i < 200 ? CMTime(value: Int64(i), timescale: 60) : CMTime(value: Int64(200 + (i - 200) * 2), timescale: 60) }
    var changes = [String]()
    var pendingAck = [Int]()
    for i in 0..<frames {
        switch i {
        case 90: changes.append("bitrate→3M@90: \(set(s, kVTCompressionPropertyKey_AverageBitRate, 3_000_000 as CFNumber))")
        case 150: changes.append("bitrate→12M@150: \(set(s, kVTCompressionPropertyKey_AverageBitRate, 12_000_000 as CFNumber))")
        case 200: changes.append("fps→30@200: \(set(s, kVTCompressionPropertyKey_ExpectedFrameRate, 30 as CFNumber))")
        default: break
        }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        canvas.render(i, pb!)
        var opts: [CFString: Any] = [:]
        if i == 60 || i == 180 { opts[kVTEncodeFrameOptionKey_ForceKeyFrame] = true }
        if !pendingAck.isEmpty { opts[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = pendingAck; pendingAck = [] }
        let est = VTCompressionSessionEncodeFrame(s, imageBuffer: pb!, presentationTimeStamp: pts(i), duration: .invalid,
                                                  frameProperties: opts.isEmpty ? nil : opts as CFDictionary, infoFlagsOut: nil) { status, _, sb in
            guard let sb, let bb = CMSampleBufferGetDataBuffer(sb) else { sink.put(i, .init(data: [], fd: nil, sync: false, ltr: false, status: status)); return }
            var data = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(bb))
            data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            let a = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]])?.first ?? [:]
            let ltr = (a[kVTSampleAttachmentKey_RequireLTRAcknowledgementToken] as? NSNumber)?.intValue
            sink.put(i, .init(data: data, fd: CMSampleBufferGetFormatDescription(sb), sync: !((a[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false),
                              ltr: ltr != nil, status: status, token: ltr))
        }
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: pts(i))
        if est != noErr { rep.add("\(name): encode \(i) → \(est)"); return }
        if let token = sink.all[i]?.token { pendingAck.append(token) }
    }
    let out = sink.all
    let emitted = out.keys.sorted().filter { !(out[$0]!.data.isEmpty) }
    let syncs = emitted.filter { out[$0]!.sync }
    rep.add("\(name): \(emitted.count)/\(frames) frames; sync frames \(syncs) (forced at 60, 180); LTR tokens on \(emitted.filter { out[$0]!.ltr }.count) frames; property changes \(changes.joined(separator: ", "))")

    // Bitrate tracking: achieved Mbps per window vs target.
    func mbps(_ r: Range<Int>) -> String {
        let ix = r.filter { out[$0].map { !$0.data.isEmpty && !$0.sync } ?? false }
        let bytes = ix.map { out[$0]!.data.count }.reduce(0, +)
        return String(format: "%.1f", Double(bytes) * 8 * Double(fps(r.lowerBound)) / Double(max(1, ix.count)) / 1e6)
    }
    var settle = "never"
    for i in 90..<150 {
        let w = (i..<min(i + 5, 150)).compactMap { out[$0]?.data.count }
        if !w.isEmpty, Double(w.reduce(0, +)) / Double(w.count) <= 3_000_000 / 8 / 60 * 1.25 { settle = "\(i - 90) frames"; break }
    }
    rep.add("\(name): achieved Mbps — 30-59 @8: \(mbps(30..<60)) · 100-149 @3: \(mbps(100..<150)) (5-frame mean ≤1.25× budget after \(settle)) · 160-179 @12: \(mbps(160..<180)) · 210-239 @12, 30 fps: \(mbps(210..<240))")

    // NAL types: in-band parameter sets? IDR vs CRA?
    let desc = { (i: Int) in "\(i):\(nalTypes(out[i]?.data ?? [], hevc: hevc))" }
    rep.add("\(name): NAL types — \(desc(0)) \(desc(1)) \(desc(60)) \(desc(180)) (H.264 5=IDR 1=slice 7/8=SPS/PPS; HEVC 19/20=IDR 21=CRA 1=TRAIL 32–34=VPS/SPS/PPS)")

    // Format description stability and parameter-set round trip.
    let fds = emitted.compactMap { out[$0]!.fd }
    var changed = [Int]()
    for (k, i) in emitted.enumerated().dropFirst() where !CMFormatDescriptionEqual(fds[k], otherFormatDescription: fds[k - 1]) { changed.append(i) }
    guard let fd180 = out[180]?.fd, let fd60 = out[60]?.fd else { rep.add("\(name): keyframes 60/180 missing"); return }
    let (sets, nalLen) = parameterSets(fd180, hevc: hevc)
    let (rebuilt, rst) = rebuild(sets, nalLength: nalLen, hevc: hevc)
    rep.add("\(name): format description changed at frames \(changed.isEmpty ? "none" : "\(changed)"); parameter sets \(sets.count) (\(sets.map(\.count)) B), NAL length \(nalLen); rebuilt from bytes: \(rst == noErr && rebuilt != nil)")

    // Reference decode, then a fresh decoder that only has the rebuilt parameter sets and joins at a forced keyframe.
    let full = decode(out, indices: emitted, using: fds[0], fps: fps)
    let fullErrors = full.values.filter { $0.0 != noErr }.count
    for join in [60, 180] {
        let range = emitted.filter { $0 >= join && $0 < (join == 60 ? 90 : 240) }
        let (ps, nl) = parameterSets(join == 60 ? fd60 : fd180, hevc: hevc)
        guard let fd = rebuild(ps, nalLength: nl, hevc: hevc).0 else { rep.add("\(name): rebuild failed"); continue }
        let fresh = decode(out, indices: range, using: fd, fps: fps)
        let errors = fresh.values.filter { $0.0 != noErr }.count
        let identical = range.allSatisfy { fresh[$0]?.1 != nil && fresh[$0]?.1 == full[$0]?.1 }
        rep.add("\(name): fresh decoder joins at forced keyframe \(join) → \(errors) errors over \(range.count) frames, bit-identical to full decode: \(identical) (full decode errors \(fullErrors))")
    }
}

private func hdrCheck(_ codec: CMVideoCodecType, rep: inout Report) {
    let hevc = codec == kCMVideoCodecType_HEVC
    let name = hevc ? "HEVC " : "H.264"
    let (sess, st) = lowLatencyEncoder(codec, 1920, 1080, pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
    guard let s = sess else { rep.add("\(name) 10-bit: create failed \(st)"); return }
    defer { VTCompressionSessionInvalidate(s) }
    var r = [String]()
    if hevc { r.append("Main10 profile \(set(s, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main10_AutoLevel))") }
    r.append("OutputBitDepth=10 \(set(s, kVTCompressionPropertyKey_OutputBitDepth, 10 as CFNumber))")
    r.append("BT.2020 \(set(s, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_2020))")
    r.append("PQ \(set(s, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ))")
    r.append("2020 matrix \(set(s, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_2020))")
    r.append("RealTime \(set(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue))")
    r.append("EnableLTR \(set(s, kVTCompressionPropertyKey_EnableLTR, kCFBooleanTrue))")
    VTCompressionSessionPrepareToEncodeFrames(s)
    let sink = Sink()
    guard let pool = VTCompressionSessionGetPixelBufferPool(s) else { rep.add("\(name) 10-bit HDR low-latency: \(r.joined(separator: ", ")); no pixel buffer pool"); return }
    for i in 0..<10 {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(pb!, plane)!.assumingMemoryBound(to: UInt16.self)
            let rows = CVPixelBufferGetHeightOfPlane(pb!, plane), stride16 = CVPixelBufferGetBytesPerRowOfPlane(pb!, plane) / 2
            let cols = CVPixelBufferGetWidthOfPlane(pb!, plane) * (plane == 0 ? 1 : 2)
            for y in 0..<rows { for x in 0..<cols { base[y * stride16 + x] = UInt16(plane == 0 ? 64 + ((x + y + i * 8) % 876) : 512) << 6 } }
        }
        CVPixelBufferUnlockBaseAddress(pb!, [])
        VTCompressionSessionEncodeFrame(s, imageBuffer: pb!, presentationTimeStamp: CMTime(value: Int64(i), timescale: 60), duration: .invalid,
                                        frameProperties: nil, infoFlagsOut: nil) { status, _, sb in
            guard let sb, let bb = CMSampleBufferGetDataBuffer(sb) else { sink.put(i, .init(data: [], fd: nil, sync: false, ltr: false, status: status)); return }
            var data = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(bb))
            data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            sink.put(i, .init(data: data, fd: CMSampleBufferGetFormatDescription(sb), sync: false, ltr: false, status: status))
        }
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: CMTime(value: Int64(i), timescale: 60))
    }
    let out = sink.all
    let ok = out.values.filter { !$0.data.isEmpty }.count
    var depth = "?"
    if let fd = out[0]?.fd {
        let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
        depth = "\(ext[kCMFormatDescriptionExtension_BitsPerComponent as String] ?? "n/a") bits, transfer \(ext[kCMFormatDescriptionExtension_TransferFunction as String] ?? "n/a")"
        let dec = decode(out, indices: Array(0..<10), using: fd, fps: { _ in 60 })
        depth += ", decode errors \(dec.values.filter { $0.0 != noErr }.count)/\(dec.count)"
    }
    rep.add("\(name) 10-bit HDR low-latency: \(r.joined(separator: ", ")); \(ok)/10 frames out; stream: \(depth)")
}

private func supportedKeys(_ codec: CMVideoCodecType) -> Set<String> {
    guard let s = lowLatencyEncoder(codec, 1920, 1080, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange).0 else { return [] }
    defer { VTCompressionSessionInvalidate(s) }
    var dict: CFDictionary?
    VTSessionCopySupportedPropertyDictionary(s, supportedPropertyDictionaryOut: &dict)
    return Set(((dict as? [String: Any]) ?? [:]).keys)
}

public func codecAPIProbe() -> Report {
    var rep = Report("H.264 vs HEVC — API parity for what Lightray needs (low-latency hardware encoders)")
    let h264Keys = supportedKeys(kCMVideoCodecType_H264), hevcKeys = supportedKeys(kCMVideoCodecType_HEVC)
    let strip = { (k: String) in k.replacingOccurrences(of: "kVTCompressionPropertyKey_", with: "") }
    rep.add("supported properties: H.264 \(h264Keys.count), HEVC \(hevcKeys.count)")
    rep.add("  only H.264: \(h264Keys.subtracting(hevcKeys).map(strip).sorted())")
    rep.add("  only HEVC:  \(hevcKeys.subtracting(h264Keys).map(strip).sorted())")
    let needed: [CFString] = [kVTCompressionPropertyKey_RealTime, kVTCompressionPropertyKey_AllowFrameReordering, kVTCompressionPropertyKey_AverageBitRate,
                              kVTCompressionPropertyKey_ExpectedFrameRate, kVTCompressionPropertyKey_MaxKeyFrameInterval, kVTCompressionPropertyKey_EnableLTR,
                              kVTCompressionPropertyKey_ProfileLevel, kVTCompressionPropertyKey_ColorPrimaries, kVTCompressionPropertyKey_TransferFunction,
                              kVTCompressionPropertyKey_YCbCrMatrix, kVTCompressionPropertyKey_HDRMetadataInsertionMode, kVTCompressionPropertyKey_OutputBitDepth,
                              kVTCompressionPropertyKey_DataRateLimits, kVTCompressionPropertyKey_ConstantBitRate, kVTCompressionPropertyKey_MaxFrameDelayCount,
                              kVTCompressionPropertyKey_MaxH264SliceBytes, kVTCompressionPropertyKey_BaseLayerFrameRateFraction]
    rep.add("  checklist (H.264/HEVC): " + needed.map { k in "\(strip(k as String)) \(h264Keys.contains(k as String) ? "✓" : "✗")/\(hevcKeys.contains(k as String) ? "✓" : "✗")" }.joined(separator: ", "))
    rep.add("hardware decode: H.264 \(VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)), HEVC \(VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC))")
    rep.add("intra-refresh: no VideoToolbox property or frame option exists (either codec)")
    guard let canvas = ZoomCanvas(photo: "/System/Library/Wallpapers/.default/DefaultAerial.jpg", width: 1920, height: 1080) else {
        rep.add("cannot load test photo"); return rep
    }
    scriptedStream(kCMVideoCodecType_H264, canvas: canvas, rep: &rep)
    scriptedStream(kCMVideoCodecType_HEVC, canvas: canvas, rep: &rep)
    hdrCheck(kCMVideoCodecType_H264, rep: &rep)
    hdrCheck(kCMVideoCodecType_HEVC, rep: &rep)
    return rep
}
