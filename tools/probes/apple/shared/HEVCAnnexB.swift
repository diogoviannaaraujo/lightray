// HEVC Annex B parsing shared by the Apple probes: split a byte stream into NAL units, group them
// into access units, build a VideoToolbox format description from in-band parameter sets, and
// wrap one access unit as a length-prefixed CMSampleBuffer.
import CoreMedia
import Foundation

enum HEVC {
    static let vps = 32, sps = 33, pps = 34, aud = 35, suffixSEI = 40

    /// NAL unit payloads, start codes removed. Emulation-prevention bytes are kept.
    static func nalUnits(_ d: Data) -> [Data] {
        let b = [UInt8](d)
        var starts: [(code: Int, payload: Int)] = []
        var i = 0
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                starts.append((code: (i > 0 && b[i - 1] == 0) ? i - 1 : i, payload: i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        var nals: [Data] = []
        for (k, s) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1].code : b.count
            if end > s.payload { nals.append(Data(b[s.payload..<end])) }
        }
        return nals
    }

    static func type(_ n: Data) -> Int { Int((n[n.startIndex] >> 1) & 0x3f) }
    static func isVCL(_ n: Data) -> Bool { type(n) < 32 }
    /// IDR_W_RADL (19), IDR_N_LP (20).
    static func isIDR(_ n: Data) -> Bool { [19, 20].contains(type(n)) }

    /// Groups NAL units into access units. A VCL NAL unit whose first_slice_segment_in_pic_flag is
    /// set starts a new picture; non-VCL units other than suffix SEI belong to the picture after them.
    static func accessUnits(_ nals: [Data]) -> [[Data]] {
        var aus: [[Data]] = []
        var current: [Data] = []
        var pending: [Data] = []
        var hasVCL = false
        for n in nals where n.count > 2 {
            if isVCL(n) {
                let firstSlice = (n[n.startIndex + 2] & 0x80) != 0
                if firstSlice && hasVCL { aus.append(current); current = []; hasVCL = false }
                current += pending
                pending = []
                current.append(n)
                hasVCL = true
            } else if type(n) == suffixSEI {
                current.append(n)
            } else {
                pending.append(n)
            }
        }
        if hasVCL { aus.append(current) }
        return aus
    }

    /// A format description from the first VPS, SPS and PPS in the access unit, if all are present.
    static func formatDescription(_ au: [Data]) -> CMFormatDescription? {
        guard let v = au.first(where: { type($0) == vps }), let s = au.first(where: { type($0) == sps }),
              let p = au.first(where: { type($0) == pps }) else { return nil }
        let sets = [v, s, p]
        var fmt: CMFormatDescription?
        let st = sets[0].withUnsafeBytes { a in sets[1].withUnsafeBytes { b in sets[2].withUnsafeBytes { c in
            let ptrs: [UnsafePointer<UInt8>] = [a.bindMemory(to: UInt8.self).baseAddress!, b.bindMemory(to: UInt8.self).baseAddress!,
                                                c.bindMemory(to: UInt8.self).baseAddress!]
            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: 3, parameterSetPointers: ptrs,
                                                                       parameterSetSizes: sets.map(\.count), nalUnitHeaderLength: 4,
                                                                       extensions: nil, formatDescriptionOut: &fmt)
        } } }
        return st == noErr ? fmt : nil
    }

    /// One access unit as a 4-byte-length-prefixed sample, parameter sets and delimiters excluded.
    static func sampleBuffer(_ au: [Data], format: CMFormatDescription, index: Int, fps: Int32 = 60) -> CMSampleBuffer? {
        var payload = Data()
        for n in au where ![vps, sps, pps, aud].contains(type(n)) {
            var len = UInt32(n.count).bigEndian
            payload.append(Data(bytes: &len, count: 4))
            payload.append(n)
        }
        guard !payload.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: payload.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: payload.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        _ = payload.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: fps), presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: fps),
                                        decodeTimeStamp: .invalid)
        var size = payload.count
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr
        else { return nil }
        return sb
    }

    /// Annex B bytes for one encoded CMSampleBuffer (4-byte length-prefixed NAL units), with the
    /// format description's parameter sets prepended when `withParameterSets` is set.
    static func annexB(_ sb: CMSampleBuffer, withParameterSets: Bool) -> Data {
        var out = Data()
        let startCode = Data([0, 0, 0, 1])
        if withParameterSets, let fmt = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var p: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &p,
                                                                   parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let p { out.append(startCode); out.append(p, count: size) }
            }
        }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return out }
        let total = CMBlockBufferGetDataLength(bb)
        var bytes = [UInt8](repeating: 0, count: total)
        CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: total, destination: &bytes)
        var off = 0
        while off + 4 <= total {
            let len = Int(bytes[off]) << 24 | Int(bytes[off + 1]) << 16 | Int(bytes[off + 2]) << 8 | Int(bytes[off + 3])
            off += 4
            guard off + len <= total else { break }
            out.append(startCode)
            out.append(contentsOf: bytes[off..<off + len])
            off += len
        }
        return out
    }
}
