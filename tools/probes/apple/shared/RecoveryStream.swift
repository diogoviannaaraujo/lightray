// Recovery streams: an HEVC Annex B file plus a JSON manifest naming the frames a receiver never
// got ("lost") and the frame the encoder produced to recover ("recovery"). Every probe that tests
// an encoder's recovery mechanism (VideoToolbox here, NVENC and QSV on Windows) writes this format,
// and verify(_:) checks it with the decoder a Lightray client actually uses.
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct RecoveryManifest: Codable {
    struct Frame: Codable {
        var index: Int
        var bytes: Int
        var keyframe: Bool
    }
    var encoder: String        // "videotoolbox", "nvenc", "qsv"
    var device: String
    var scenario: String       // "idr", "ltr", "rfi", "intra-refresh", ...
    var width: Int
    var height: Int
    var fps: Int
    var lost: [Int]
    var recovery: Int
    var frames: [Frame]
    var notes: String?
}

enum RecoveryVerifier {
    struct Decoded {
        var status: OSStatus
        var hash: UInt64?
    }

    /// Decodes `aus` in order, skipping the indices in `skip`, and returns one entry per access unit.
    /// A decoder that follows parameter-set changes carried in later access units.
    static func decode(_ aus: [[Data]], format: CMFormatDescription, skip: Set<Int>, fps: Int32) -> [Decoded?] {
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        func makeSession(_ f: CMFormatDescription) -> VTDecompressionSession? {
            var s: VTDecompressionSession?
            return VTDecompressionSessionCreate(allocator: nil, formatDescription: f, decoderSpecification: nil, imageBufferAttributes: attrs,
                                                outputCallback: nil, decompressionSessionOut: &s) == noErr ? s : nil
        }
        var format = format
        var paramSets = parameterSets(aus.first ?? [])
        guard var session = makeSession(format) else { return Array(repeating: nil, count: aus.count) }
        defer { VTDecompressionSessionInvalidate(session) }
        var out: [Decoded?] = Array(repeating: nil, count: aus.count)
        for (i, au) in aus.enumerated() where !skip.contains(i) {
            let sets = parameterSets(au)
            if !sets.isEmpty, sets != paramSets, let f = HEVC.formatDescription(au) {
                paramSets = sets
                format = f
                if !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: f) {
                    VTDecompressionSessionInvalidate(session)
                    guard let s = makeSession(f) else { break }
                    session = s
                }
            }
            guard let sb = HEVC.sampleBuffer(au, format: format, index: i, fps: fps) else {
                out[i] = Decoded(status: -1, hash: nil)
                continue
            }
            let sem = DispatchSemaphore(value: 0)
            var result = Decoded(status: noErr, hash: nil)
            let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                result.status = status
                if status == noErr, let image { result.hash = hash(image) }
                sem.signal()
            }
            if st != noErr { result.status = st } else { sem.wait() }
            out[i] = result
        }
        return out
    }

    static func parameterSets(_ au: [Data]) -> [Data] {
        au.filter { [HEVC.vps, HEVC.sps, HEVC.pps].contains(HEVC.type($0)) }
    }

    /// FNV-1a over the visible bytes of every plane.
    static func hash(_ pb: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ base: UnsafeRawPointer, rows: Int, rowBytes: Int, stride: Int) {
            for r in 0..<rows {
                let row = base.advanced(by: r * stride).assumingMemoryBound(to: UInt8.self)
                for c in 0..<rowBytes { h = (h ^ UInt64(row[c])) &* 0x100000001b3 }
            }
        }
        if CVPixelBufferIsPlanar(pb) {
            for p in 0..<CVPixelBufferGetPlaneCount(pb) {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, p) else { continue }
                let w = CVPixelBufferGetWidthOfPlane(pb, p), stride = CVPixelBufferGetBytesPerRowOfPlane(pb, p)
                let bytesPerPixel = max(1, stride / max(1, CVPixelBufferGetWidthOfPlane(pb, p)))
                mix(base, rows: CVPixelBufferGetHeightOfPlane(pb, p), rowBytes: min(stride, w * bytesPerPixel), stride: stride)
            }
        } else if let base = CVPixelBufferGetBaseAddress(pb) {
            let stride = CVPixelBufferGetBytesPerRow(pb)
            mix(base, rows: CVPixelBufferGetHeight(pb), rowBytes: stride, stride: stride)
        }
        return h
    }

    /// One human-readable verdict line for a manifest and its stream.
    static func verify(manifestURL: URL) -> String {
        guard let json = try? Data(contentsOf: manifestURL),
              let m = try? JSONDecoder().decode(RecoveryManifest.self, from: json) else {
            return "ERROR \(manifestURL.lastPathComponent): unreadable manifest"
        }
        let streamURL = manifestURL.deletingPathExtension().appendingPathExtension("hevc")
        guard let bytes = try? Data(contentsOf: streamURL) else { return "ERROR \(streamURL.lastPathComponent): missing stream" }
        let aus = HEVC.accessUnits(HEVC.nalUnits(bytes))
        let name = "\(m.encoder)/\(m.scenario)"
        guard aus.count == m.frames.count else {
            return "ERROR \(name): \(aus.count) access units in the stream, \(m.frames.count) in the manifest"
        }
        guard let format = HEVC.formatDescription(aus[0]) else { return "ERROR \(name): no parameter sets in the first access unit" }
        let fps = Int32(max(1, m.fps))
        let full = decode(aus, format: format, skip: [], fps: fps)
        let lossy = decode(aus, format: format, skip: Set(m.lost), fps: fps)
        let fullErrors = full.enumerated().filter { $0.element?.status != noErr }.map(\.offset)
        let afterLoss = (m.lost.min() ?? m.recovery)..<aus.count
        var errors: [(Int, OSStatus)] = []
        var mismatches: [Int] = []
        for i in afterLoss where !m.lost.contains(i) {
            guard let d = lossy[i] else { continue }
            if d.status != noErr { errors.append((i, d.status)); continue }
            if d.hash != full[i]?.hash { mismatches.append(i) }
        }
        // First frame from which every later frame decodes and matches the complete decode.
        var converged: Int? = nil
        for start in afterLoss where !m.lost.contains(start) {
            if (start..<aus.count).allSatisfy({ i in lossy[i]?.status == noErr && lossy[i]?.hash == full[i]?.hash }) { converged = start; break }
        }
        let rec = m.frames[m.recovery]
        let desc = String(format: "recovery frame %d (%@, %.1f KB), lost %d–%d", m.recovery, rec.keyframe ? "keyframe" : "predicted",
                          Double(rec.bytes) / 1024, m.lost.min() ?? -1, m.lost.max() ?? -1)
        let verdict: String
        if !fullErrors.isEmpty {
            verdict = "FAIL complete decode has errors at frames \(fullErrors.prefix(8))"
        } else if converged == m.recovery && errors.filter({ $0.0 >= m.recovery }).isEmpty {
            let refused = errors.filter { $0.0 < m.recovery }
            verdict = "PASS frames \(m.recovery)–\(aus.count - 1) identical to the complete decode" +
                (refused.isEmpty ? "" : "; decoder refused \(refused.count) frame(s) before recovery (status \(refused[0].1))")
        } else if let c = converged {
            verdict = "LATE converges at frame \(c), not at \(m.recovery); errors=\(errors.count) mismatches=\(mismatches.count)"
        } else {
            let firstErr = errors.first.map { "first error at \($0.0) status \($0.1)" } ?? "no decode errors"
            verdict = "FAIL never converges; \(firstErr); mismatches=\(mismatches.count)"
        }
        return "\(verdict) — \(name) on \(m.device), \(m.width)x\(m.height), \(desc)"
    }
}
