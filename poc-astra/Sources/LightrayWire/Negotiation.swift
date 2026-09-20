import LightrayPrimitives

public enum StreamKind: UInt8, Sendable {
    case video = 1
    case audio = 2
    case reliable = 3
    case datagram = 4
}
public enum StreamDirection: UInt8, Sendable {
    case hostToClient = 1
    case clientToHost = 2
    case bidirectional = 3
}
public struct StreamDescriptor: Sendable, Equatable {
    public var id: UInt8
    public var kind: StreamKind
    public var direction: StreamDirection
    public init(id: UInt8, kind: StreamKind, direction: StreamDirection) {
        self.id = id
        self.kind = kind
        self.direction = direction
    }
    public static let defaults: [Self] = [.init(id: 1, kind: .video, direction: .hostToClient), .init(id: 2, kind: .audio, direction: .hostToClient), .init(id: 3, kind: .audio, direction: .clientToHost), .init(id: 4, kind: .video, direction: .clientToHost), .init(id: 5, kind: .reliable, direction: .bidirectional), .init(id: 6, kind: .datagram, direction: .bidirectional)]
    public static func validate(_ streams: [Self]) throws { guard !streams.isEmpty, streams.count <= 32, streams.allSatisfy({ $0.id != 0 }), Set(streams.map(\.id)).count == streams.count else { throw WireError.malformed } }
}
public struct HandshakeParameters: Sendable {
    public var configuration = Configuration()
    public var timestamp: UInt64?
    public var ltr = true
    public var streams = StreamDescriptor.defaults
    public var resumeSessionID: UInt32?
    public var pipelineIdleAfter: UInt64 = 60_000_000_000
    public var graceWindow: UInt64 = 1_800_000_000_000
    public var resetToken: [UInt8] = []
    public init() {}
    public func encode() throws -> [UInt8] {
        try StreamDescriptor.validate(streams)
        _ = try configuration.validated()
        var w = ByteWriter()
        try w.chunk(1, configuration.encode())
        if let timestamp {
            var value = ByteWriter()
            value.put(timestamp)
            try w.chunk(2, value.bytes)
        }
        try w.chunk(3, [ltr ? 1 : 0, 0])
        try w.chunk(4, streams.flatMap { [$0.id, $0.kind.rawValue, $0.direction.rawValue] })
        var mtu = ByteWriter()
        mtu.put(configuration.maxDatagramSize)
        try w.chunk(5, mtu.bytes)
        if let resumeSessionID {
            var value = ByteWriter()
            value.put(resumeSessionID)
            try w.chunk(6, value.bytes)
        }
        var lifecycle = ByteWriter()
        lifecycle.put(pipelineIdleAfter)
        lifecycle.put(graceWindow)
        try w.chunk(7, lifecycle.bytes)
        if !resetToken.isEmpty {
            guard resetToken.count == 16 else { throw WireError.malformed }
            try w.chunk(8, resetToken)
        }
        return w.bytes
    }
    public static func decode(_ bytes: RawSpan) throws -> Self {
        var result = Self()
        var reader = ByteReader(bytes)
        var seen: Set<UInt8> = []
        var mtu: UInt16?
        while let chunk = try reader.nextChunk() {
            if chunk.type <= 8 { guard seen.insert(chunk.type).inserted else { throw WireError.malformed } }
            var r = ByteReader(chunk.body)
            switch chunk.type {
            case 1: result.configuration = try Configuration.decode(r.rest())
            case 2: result.timestamp = try r.u64()
            case 3:
                result.ltr = try r.u8() & 1 != 0
                guard try r.u8() == 0 else { throw WireError.malformed }
            case 4:
                result.streams = []
                while r.remaining > 0 {
                    let id = try r.u8()
                    guard let kind = StreamKind(rawValue: try r.u8()), let direction = StreamDirection(rawValue: try r.u8()) else { throw WireError.malformed }
                    result.streams.append(.init(id: id, kind: kind, direction: direction))
                }
                try StreamDescriptor.validate(result.streams)
            case 5: mtu = try r.u16()
            case 6: result.resumeSessionID = try r.u32()
            case 7:
                result.pipelineIdleAfter = try r.u64()
                result.graceWindow = try r.u64()
                guard result.pipelineIdleAfter <= result.graceWindow else { throw WireError.malformed }
            case 8: result.resetToken = try r.take(16).copyBytes()
            default: try r.skip(r.remaining)
            }
            guard r.remaining == 0 else { throw WireError.malformed }
        }
        guard seen.isSuperset(of: [1, 3, 4, 5]), mtu == result.configuration.maxDatagramSize else { throw WireError.malformed }
        return result
    }
}
