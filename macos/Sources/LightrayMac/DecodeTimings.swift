import LightrayCore

/// Measurements on the client's monotonic clock, covering successful current-epoch decodes only.
public struct DecodeTimings: Sendable {
    public private(set) var samples = 0
    public private(set) var decodeMicros = 0.0
    public private(set) var queueMicros = 0.0
    public private(set) var maximumDecodeMicros: UInt64 = 0

    public private(set) var hostSamples = 0
    public private(set) var captureMicros = 0.0
    public private(set) var encodeMicros = 0.0
    public private(set) var lastHostSample: HostFrameTimings?

    public var meanCaptureMillis: Double? { hostSamples > 0 ? captureMicros / Double(hostSamples) / 1000 : nil }
    public var meanEncodeMillis: Double? { hostSamples > 0 ? encodeMicros / Double(hostSamples) / 1000 : nil }

    public init() {}

    public var meanDecodeMillis: Double? { samples > 0 ? decodeMicros / Double(samples) / 1000 : nil }
    public var meanQueueMillis: Double? { samples > 0 ? queueMicros / Double(samples) / 1000 : nil }

    public mutating func record(completedAt: UInt64, decodeStarted: UInt64, decodeFinished: UInt64, hostTimings: HostFrameTimings? = nil) {
        guard completedAt <= decodeStarted, decodeStarted <= decodeFinished else { return }
        let duration = decodeFinished - decodeStarted
        if let hostTimings {
            hostSamples += 1
            captureMicros += Double(hostTimings.captureMicros)
            encodeMicros += Double(hostTimings.encodeMicros)
            lastHostSample = hostTimings
        }
        samples += 1
        decodeMicros += Double(duration)
        queueMicros += Double(decodeStarted - completedAt)
        maximumDecodeMicros = max(maximumDecodeMicros, duration)
    }
}
