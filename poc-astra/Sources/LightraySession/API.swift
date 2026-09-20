import LightrayCrypto
@_exported import LightrayPrimitives
@_exported import LightrayStats
@_exported import LightrayStreams
@_exported import LightrayWire

public struct PeerAddress: Hashable, Sendable {
    public var host: String
    public var port: UInt16
    public init(host: String = "::1", port: UInt16) {
        self.host = host
        self.port = port
    }
}
public enum Role: Sendable { case host, client }
public enum SessionState: Sendable { case active, parked, closed }
public enum RefreshPreference: UInt8, Sendable { case ltr, idr }
public enum ConnectionEvent {
    case connected, parked, idle, resumed, expired
    case closed(UInt16)
    case sessionLost
    case rebound(PeerAddress)
    case frame(ReassembledFrame, FrameInfo)
    case reliable(UInt8, [UInt8])
    case datagram(UInt8, [UInt8])
    case refreshRequired(UInt8, RefreshPreference, [UInt32])
    case configurationChanged(Configuration)
    case bitrateChanged(UInt32)
    case reconfigureRejected(UInt32)
    case error(String)
}
public struct Transmit: Sendable {
    public var bytes: [UInt8]
    public var peer: PeerAddress
    public init(bytes: [UInt8], peer: PeerAddress) {
        self.bytes = bytes
        self.peer = peer
    }
}
public struct SessionPolicy: Sendable {
    public var parkAfterSilence: UInt64 = 2_000_000_000
    public var pipelineIdleAfter: UInt64 = 60_000_000_000
    public var graceWindow: UInt64 = 1_800_000_000_000
    public var keepaliveInterval: UInt64 = 250_000_000
    public var ltrAckInterval: UInt64 = 250_000_000
    public var maxParkedSessions = 128
    public init() {}
}
public protocol DecoderHost: AnyObject {
    func submit(frame: ReassembledFrame, info: FrameInfo)
    func reset()
}
public protocol AudioSink: AnyObject {
    func submit(packet: ReassembledFrame, captureTime: UInt32, gap: Bool)
    var bufferedNanoseconds: UInt64 { get }
}
public protocol DisplayClock {
    var refreshInterval: UInt64 { get }
    func nextPresentTime(after: Instant) -> Instant
}
