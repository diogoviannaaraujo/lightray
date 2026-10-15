import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public struct CodecError: Error, CustomStringConvertible {
    public let description: String
    init(_ what: String, _ status: OSStatus) { description = "\(what) failed: \(status)" }
}

/// HEVC from the hardware encoder in low-latency mode, as `notes/macos-host.md` measured it:
/// real time, no reordering, keyframes only when asked for. Its output is already the payload
/// format `docs/video.md` requires, NAL units behind 4-byte lengths, and its format description
/// gives the parameter sets for `CODEC_CONFIG`.
public final class VideoEncoder {
    public let width: Int
    public let height: Int
    private var session: VTCompressionSession?
    private let output: @Sendable (EncodedFrame) -> Void
    private var lastPresentation: Int64 = 0

    public init(width: Int, height: Int, frameRate: Int, bitrate: Int, output: @escaping @Sendable (EncodedFrame) -> Void) throws {
        self.width = width
        self.height = height
        self.output = output
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: specification as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let session = created else { throw CodecError("VTCompressionSessionCreate", status) }
        self.session = session
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_HEVC_Main_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: frameRate,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: Int32.max,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 0,
        ]
        for (key, value) in properties {
            let s = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            if s != noErr, key != kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration {
                FileHandle.standardError.write(Data("encoder: \(key) not set (\(s))\n".utf8))
            }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit { invalidate() }

    public func invalidate() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    /// Encodes one picture. `output` runs on VideoToolbox's thread, or not at all if the encoder
    /// skips the frame, which in low-latency mode it does under a tight budget.
    public func encode(_ pixelBuffer: CVPixelBuffer, captureTimeMicros: UInt64, forceKeyframe: Bool) {
        guard let session else { return }
        // Presentation times must increase, including for a picture encoded twice.
        let pts = max(Int64(captureTimeMicros), lastPresentation + 1)
        lastPresentation = pts
        let options: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let output = self.output
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000),
            duration: .invalid, frameProperties: options, infoFlagsOut: nil
        ) { status, flags, sample in
            guard status == noErr, !flags.contains(.frameDropped), let sample,
                let frame = Self.frame(from: sample, captureTimeMicros: captureTimeMicros)
            else { return }
            output(frame)
        }
    }

    static func frame(from sample: CMSampleBuffer, captureTimeMicros: UInt64) -> EncodedFrame? {
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample)
        else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var payload = Bytes(repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &payload) == noErr else {
            return nil
        }
        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
            let first = attachments.first, first[kCMSampleAttachmentKey_NotSync] as? Bool == true
        {
            isKeyframe = false
        }
        let (config, nalLength) = parameterSets(format)
        if nalLength != 4 { payload = relengthen(payload, from: nalLength) }
        return EncodedFrame(
            isKeyframe: isKeyframe, payload: payload, codecConfig: isKeyframe ? config : nil,
            captureTimeMicros: captureTimeMicros)
    }

    /// VPS, SPS and PPS, picked out by NAL unit type, and the NAL length size.
    static func parameterSets(_ format: CMFormatDescription) -> (CodecConfig?, Int) {
        var count = 0
        var nalLength: Int32 = 4
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLength) == noErr
        else { return (nil, 4) }
        var sets: [UInt8: Bytes] = [:]
        for i in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer, size > 0
            else { continue }
            let nal = Bytes(UnsafeBufferPointer(start: pointer, count: size))
            sets[(nal[0] >> 1) & 0x3f] = nal
        }
        guard let vps = sets[32], let sps = sets[33], let pps = sets[34] else { return (nil, Int(nalLength)) }
        return (CodecConfig(vps: vps, sps: sps, pps: pps), Int(nalLength))
    }

    /// Rewrites NAL length prefixes of another size as 4 bytes.
    static func relengthen(_ data: Bytes, from size: Int) -> Bytes {
        var out = ByteWriter(capacity: data.count + 64)
        var i = 0
        while i + size <= data.count {
            let length = data[i..<i + size].reduce(0) { $0 << 8 | Int($1) }
            i += size
            guard i + length <= data.count else { break }
            out.u32(UInt32(length))
            out.append(data[i..<i + length])
            i += length
        }
        return out.bytes
    }
}
