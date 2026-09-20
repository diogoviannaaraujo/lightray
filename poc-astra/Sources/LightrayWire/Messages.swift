import LightrayPrimitives

public enum ChunkType: UInt8, Sendable {
    case media = 1
    case reliable = 2
    case datagram = 3
    case feedback = 0x10
    case nack = 0x11
    case frameAck = 0x12
    case refresh = 0x13
    case ping = 0x30
    case pong = 0x31
    case park = 0x32
    case resume = 0x33
    case close = 0x34
}
public enum FrameType: UInt8, Sendable { case idr, predicted, audio }
public enum ReferenceKind: UInt8, Sendable { case none, previous, ltr, ltrAny }
public struct FrameInfo: Sendable, Equatable {
    public var type: FrameType
    public var reference: ReferenceKind
    public var referenceID: UInt32
    public var ltrMark: Bool
    public var generation: UInt32
    public var captureTime: UInt32
    public var codecConfig: [UInt8]
    public init(type: FrameType = .predicted, reference: ReferenceKind = .previous, referenceID: UInt32 = 0, ltrMark: Bool = false, generation: UInt32 = 0, captureTime: UInt32 = 0, codecConfig: [UInt8] = []) {
        self.type = type
        self.reference = reference
        self.referenceID = referenceID
        self.ltrMark = ltrMark
        self.generation = generation
        self.captureTime = captureTime
        self.codecConfig = codecConfig
    }
    public func encode() throws -> [UInt8] {
        guard codecConfig.count <= 65532, type != .idr || !codecConfig.isEmpty else { throw WireError.malformed }
        var w = ByteWriter()
        w.put(type.rawValue)
        w.put(reference.rawValue)
        w.put(UInt8(ltrMark ? 1 : 0))
        w.put(generation)
        w.put(captureTime)
        if reference == .ltr { w.put(referenceID) }
        w.put(UInt16(codecConfig.isEmpty ? 0 : codecConfig.count + 3))
        if !codecConfig.isEmpty {
            w.put(UInt8(1))
            w.put(UInt16(codecConfig.count))
            w.bytes += codecConfig
        }
        return w.bytes
    }
    public static func decode(_ r: inout ByteReader) throws -> Self {
        guard let type = FrameType(rawValue: try r.u8()), let reference = ReferenceKind(rawValue: try r.u8()) else { throw WireError.malformed }
        let mark = try r.u8()
        let generation = try r.u32()
        let capture = try r.u32()
        let ref = reference == .ltr ? try r.u32() : 0
        var ext = ByteReader(try r.take(Int(try r.u16())))
        var config: [UInt8] = []
        while ext.remaining > 0 {
            let tag = try ext.u8()
            let value = try ext.take(Int(try ext.u16()))
            if tag == 1 { config = value.copyBytes() }
        }
        guard type != .idr || !config.isEmpty else { throw WireError.malformed }
        return .init(type: type, reference: reference, referenceID: ref, ltrMark: mark != 0, generation: generation, captureTime: capture, codecConfig: config)
    }
}
/// Convenience writer for frame/control/handshake setup, not the packet hot path.
public struct ByteWriter {
    public var bytes: [UInt8] = []
    public init() {}
    public mutating func put<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { bytes.append(contentsOf: $0) }
    }
    public mutating func chunk(_ type: UInt8, _ body: [UInt8]) throws {
        guard body.count <= 65535 else { throw WireError.overflow }
        put(type)
        put(UInt16(body.count))
        bytes += body
    }
}
extension RawSpan {
    public func copyBytes() -> [UInt8] { (0..<byteCount).map { unsafeLoad(fromUncheckedByteOffset: $0, as: UInt8.self) } }
}
public struct Configuration: Sendable, Equatable {
    public var bitrate: UInt32 = 20_000_000
    public var bitrateFloor: UInt32 = 5_000_000
    public var width: UInt16 = 1920
    public var height: UInt16 = 1080
    public var frameRate: UInt16 = 60
    public var hdr = false
    public var maxDatagramSize: UInt16 = 1200
    public var generation: UInt32 = 0
    public init() {}
    public func validated() throws -> Self {
        guard bitrateFloor > 0, bitrate >= bitrateFloor, width > 0, height > 0, frameRate > 0, frameRate <= 60, maxDatagramSize >= 256, maxDatagramSize <= 9000 else { throw WireError.malformed }
        return self
    }
    public func encode() -> [UInt8] {
        var w = ByteWriter()
        w.put(UInt8(1))
        w.put(UInt16(4))
        w.put(bitrate)
        w.put(UInt8(2))
        w.put(UInt16(4))
        w.put(bitrateFloor)
        w.put(UInt8(3))
        w.put(UInt16(4))
        w.put(width)
        w.put(height)
        w.put(UInt8(4))
        w.put(UInt16(2))
        w.put(frameRate)
        w.put(UInt8(5))
        w.put(UInt16(1))
        w.put(UInt8(hdr ? 1 : 0))
        w.put(UInt8(6))
        w.put(UInt16(2))
        w.put(maxDatagramSize)
        return w.bytes
    }
    public static func decode(_ bytes: RawSpan, base: Self = .init()) throws -> Self {
        var config = base
        var r = ByteReader(bytes)
        while r.remaining > 0 {
            let type = try r.u8()
            var v = ByteReader(try r.take(Int(try r.u16())))
            switch type {
            case 1: config.bitrate = try v.u32()
            case 2: config.bitrateFloor = try v.u32()
            case 3:
                config.width = try v.u16()
                config.height = try v.u16()
            case 4: config.frameRate = try v.u16()
            case 5: config.hdr = try v.u8() != 0
            case 6: config.maxDatagramSize = try v.u16()
            default: try v.skip(v.remaining)
            }
            guard v.remaining == 0 else { throw WireError.malformed }
        }
        return try config.validated()
    }
}
public struct NackEntry: Equatable, Sendable {
    public var frameID: UInt32
    public var first: UInt16
    public var count: UInt16
    public init(frameID: UInt32, first: UInt16, count: UInt16) {
        self.frameID = frameID
        self.first = first
        self.count = count
    }
}
public struct ReliableAcknowledgment: Sendable, Equatable {
    public var stream: UInt8
    public var sequence: UInt32
    public init(stream: UInt8, sequence: UInt32) {
        self.stream = stream
        self.sequence = sequence
    }
}
public struct Feedback: Sendable {
    public var base: UInt32
    public var baseArrival: UInt32
    public var arrivals: [Int16?]
    public var reliableAcknowledgments: [ReliableAcknowledgment]
    public init(base: UInt32, baseArrival: UInt32, arrivals: [Int16?], reliableAcknowledgments: [ReliableAcknowledgment] = []) {
        self.base = base
        self.baseArrival = baseArrival
        self.arrivals = arrivals
        self.reliableAcknowledgments = reliableAcknowledgments
    }
    public func encode() throws -> [UInt8] {
        guard arrivals.count <= 4096, reliableAcknowledgments.count <= 256 else { throw WireError.overflow }
        var w = ByteWriter()
        w.put(base)
        w.put(UInt16(arrivals.count))
        w.put(baseArrival)
        var bitmap = [UInt8](repeating: 0, count: (arrivals.count + 7) / 8)
        for i in arrivals.indices where arrivals[i] != nil { bitmap[i / 8] |= 1 << (i % 8) }
        w.bytes += bitmap
        for delta in arrivals { if let delta { w.put(delta) } }
        w.put(UInt16(reliableAcknowledgments.count))
        for ack in reliableAcknowledgments {
            w.put(ack.stream)
            w.put(ack.sequence)
        }
        return w.bytes
    }
    public static func decode(_ r: inout ByteReader) throws -> Self {
        let base = try r.u32()
        let count = Int(try r.u16())
        let arrival = try r.u32()
        guard count <= 4096 else { throw WireError.malformed }
        let bitmap = try r.take((count + 7) / 8)
        var deltas: [Int16?] = []
        deltas.reserveCapacity(count)
        for i in 0..<count { deltas.append(bitmap.unsafeLoad(fromUncheckedByteOffset: i / 8, as: UInt8.self) & (1 << (i % 8)) != 0 ? Int16(bitPattern: try r.u16()) : nil) }
        var acknowledgments: [ReliableAcknowledgment] = []
        if r.remaining > 0 {
            let count = Int(try r.u16())
            guard count <= 256 else { throw WireError.malformed }
            for _ in 0..<count { acknowledgments.append(.init(stream: try r.u8(), sequence: try r.u32())) }
        }
        guard r.remaining == 0 else { throw WireError.malformed }
        return .init(base: base, baseArrival: arrival, arrivals: deltas, reliableAcknowledgments: acknowledgments)
    }
}
