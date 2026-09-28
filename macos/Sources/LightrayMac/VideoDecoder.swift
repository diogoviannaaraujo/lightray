import CoreMedia
import CoreVideo
import Foundation
import LightrayCore
import VideoToolbox

/// HEVC decoding with VideoToolbox. Every keyframe carries its parameter sets, and a new set
/// rebuilds the decoder. With a missing reference the HEVC decoder reports an error rather than
/// showing a damaged picture (`notes/macos-host.md`), which is what tells the client to ask for a
/// keyframe.
public final class VideoDecoder {
    public enum Result {
        case picture(CVPixelBuffer, frameID: UInt32, isKeyframe: Bool)
        case failed(frameID: UInt32, status: OSStatus)
    }

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var config: CodecConfig?
    public private(set) var dimensions: CMVideoDimensions?

    public init() {}

    deinit { invalidate() }

    public func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        config = nil
    }

    /// Decodes synchronously and returns what happened.
    public func decode(_ frame: DeliveredFrame) -> Result {
        let isKeyframe = frame.header.frameType == .idr
        if isKeyframe, let config = frame.header.codecConfig, config != self.config || session == nil {
            let status = rebuild(config)
            guard status == noErr else { return .failed(frameID: frame.frameID, status: status) }
        }
        guard let session, let format else { return .failed(frameID: frame.frameID, status: kVTInvalidSessionErr) }
        guard let sample = Self.sampleBuffer(frame.payload, format: format) else {
            return .failed(frameID: frame.frameID, status: -1)
        }
        var result = Result.failed(frameID: frame.frameID, status: -1)
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { status, _, image, _, _ in
            if status == noErr, let image {
                result = .picture(image, frameID: frame.frameID, isKeyframe: isKeyframe)
            } else {
                result = .failed(frameID: frame.frameID, status: status)
            }
        }
        if status != noErr {
            if status == kVTInvalidSessionErr { invalidate() }
            return .failed(frameID: frame.frameID, status: status)
        }
        return result
    }

    private func rebuild(_ config: CodecConfig) -> OSStatus {
        invalidate()
        var created: CMFormatDescription?
        let sets = [config.vps, config.sps, config.pps]
        let status = sets[0].withUnsafeBufferPointer { vps in
            sets[1].withUnsafeBufferPointer { sps in
                sets[2].withUnsafeBufferPointer { pps in
                    let pointers = [vps.baseAddress!, sps.baseAddress!, pps.baseAddress!]
                    let sizes = sets.map(\.count)
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: nil, parameterSetCount: 3, parameterSetPointers: pointers, parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &created)
                }
            }
        }
        guard status == noErr, let created else { return status }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var session: VTDecompressionSession?
        let s = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: created, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &session)
        guard s == noErr, let session else { return s }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        self.session = session
        format = created
        self.config = config
        dimensions = CMVideoFormatDescriptionGetDimensions(created)
        return noErr
    }

    static func sampleBuffer(_ payload: ArraySlice<UInt8>, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: payload.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: payload.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        let copied = payload.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = payload.count
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
            sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }
}
