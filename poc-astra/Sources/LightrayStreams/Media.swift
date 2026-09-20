import LightrayPrimitives
import LightrayWire

public protocol ByteStorage: AnyObject {
    var count: Int { get }
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R
}
public final class FrameBytes: ByteStorage {
    private let bytes: [UInt8]
    public var count: Int { bytes.count }
    public init(_ bytes: [UInt8]) { self.bytes = bytes }
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R { try bytes.withUnsafeBytes(body) }
}
public struct EncodedFrame<Storage: ByteStorage> {
    public var stream: UInt8
    public var storage: Storage
    public var info: FrameInfo
    public init(stream: UInt8, storage: Storage, info: FrameInfo) {
        self.stream = stream
        self.storage = storage
        self.info = info
    }
}
public struct Fragmenter {
    public let stride: Int
    public init(maxDatagramSize: Int) throws {
        guard (256...9000).contains(maxDatagramSize) else { throw WireError.malformed }
        stride = maxDatagramSize - 51
    }
    public func fragmentCount(byteCount: Int) throws -> Int {
        guard byteCount > 0, byteCount <= stride * 65535 else { throw WireError.overflow }
        return (byteCount + stride - 1) / stride
    }
    public func encode(frame: UnsafeRawBufferPointer, stream: UInt8, frameID: UInt32, index: Int, retransmission: Bool = false, into output: inout OutputRawSpan) throws {
        let count = try fragmentCount(byteCount: frame.count)
        guard index >= 0, index < count else { throw WireError.malformed }
        let offset = index * stride
        let length = min(stride, frame.count - offset)
        try output.put(UInt8(1))
        try output.put(UInt16(16 + length))
        try FragmentHeader(stream: stream, flags: retransmission ? 2 : 0, frameID: frameID, index: UInt16(index), count: UInt16(count), stride: UInt16(stride)).encode(into: &output)
        guard output.freeCapacity >= length else { throw WireError.overflow }
        for i in offset..<(offset + length) { output.append(frame[i], as: UInt8.self) }
    }
}
public final class ReassembledFrame {
    private let pointer: UnsafeMutableRawPointer
    public let count: Int
    public let frameID: UInt32
    public let stream: UInt8
    public let started: Instant
    fileprivate init(pointer: UnsafeMutableRawPointer, count: Int, frameID: UInt32, stream: UInt8, started: Instant) {
        self.pointer = pointer
        self.count = count
        self.frameID = frameID
        self.stream = stream
        self.started = started
    }
    deinit { pointer.deallocate() }
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R { try body(.init(start: pointer, count: count)) }
}
private final class Assembly {
    let header: FragmentHeader
    let pointer: UnsafeMutableRawPointer
    let started: Instant
    var bits: [UInt64]
    var received = 0
    var length = 0
    var highestIndex = -1
    var transferred = false
    init(_ header: FragmentHeader, at: Instant) {
        self.header = header
        started = at
        pointer = .allocate(byteCount: Int(header.count) * Int(header.stride), alignment: 16)
        bits = .init(repeating: 0, count: (Int(header.count) + 63) / 64)
    }
    deinit { if !transferred { pointer.deallocate() } }
    func has(_ index: Int) -> Bool { bits[index / 64] & (1 << (index % 64)) != 0 }
}
public final class Reassembler {
    private var frames: [UInt64: Assembly] = [:]
    public let maxBytes: Int
    public let maxFrames: Int
    public private(set) var allocatedBytes = 0
    public var inFlight: Int { frames.count }
    public init(maxBytes: Int = 32 * 1024 * 1024, maxFrames: Int = 128) {
        self.maxBytes = maxBytes
        self.maxFrames = maxFrames
        frames.reserveCapacity(maxFrames)
    }
    private func key(_ stream: UInt8, _ id: UInt32) -> UInt64 { UInt64(stream) << 32 | UInt64(id) }
    public func receive(_ fragment: borrowing Fragment, at now: Instant) throws -> ReassembledFrame? {
        let h = fragment.header
        let k = key(h.stream, h.frameID)
        let size = Int(h.count) * Int(h.stride)
        guard h.count > 0, h.index < h.count, h.stride > 0, fragment.payload.byteCount > 0, fragment.payload.byteCount <= Int(h.stride), h.index == h.count - 1 || fragment.payload.byteCount == Int(h.stride) else { throw WireError.malformed }
        let assembly: Assembly
        if let existing = frames[k] {
            assembly = existing
            guard existing.header.count == h.count, existing.header.stride == h.stride else { throw WireError.malformed }
        } else {
            guard size <= maxBytes - allocatedBytes, frames.count < maxFrames else { throw WireError.overflow }
            assembly = Assembly(h, at: now)
            frames[k] = assembly
            allocatedBytes += size
        }
        let index = Int(h.index)
        guard !assembly.has(index) else { return nil }
        let destination = assembly.pointer.advanced(by: index * Int(h.stride))
        for i in 0..<fragment.payload.byteCount { destination.storeBytes(of: fragment.payload.unsafeLoad(fromUncheckedByteOffset: i, as: UInt8.self), toByteOffset: i, as: UInt8.self) }
        assembly.bits[index / 64] |= 1 << (index % 64)
        assembly.received += 1
        assembly.highestIndex = max(assembly.highestIndex, index)
        if h.index == h.count - 1 { assembly.length = index * Int(h.stride) + fragment.payload.byteCount }
        guard assembly.received == Int(h.count) else { return nil }
        frames.removeValue(forKey: k)
        allocatedBytes -= size
        assembly.transferred = true
        return .init(pointer: assembly.pointer, count: assembly.length, frameID: h.frameID, stream: h.stream, started: assembly.started)
    }
    public func missing(stream: UInt8, frameID: UInt32, at: Instant? = nil, tailWait: UInt64 = 0) -> [NackEntry] {
        guard let frame = frames[key(stream, frameID)] else { return [.init(frameID: frameID, first: 0, count: 0)] }
        let limit = at.map { $0.elapsed(since: frame.started) < tailWait ? frame.highestIndex + 1 : Int(frame.header.count) } ?? Int(frame.header.count)
        var result: [NackEntry] = []
        var index = 0
        while index < limit {
            if frame.has(index) {
                index += 1
                continue
            }
            let first = index
            while index < limit, !frame.has(index) { index += 1 }
            result.append(.init(frameID: frameID, first: UInt16(first), count: UInt16(index - first)))
        }
        return result
    }
    public func discard(stream: UInt8, frameID: UInt32) { if let frame = frames.removeValue(forKey: key(stream, frameID)) { allocatedBytes -= Int(frame.header.count) * Int(frame.header.stride) } }
    public func removeAll() {
        frames.removeAll(keepingCapacity: true)
        allocatedBytes = 0
    }
}
public protocol FECScheme { var identifier: UInt8 { get } }
public struct NoFEC: FECScheme {
    public let identifier: UInt8 = 0
    public init() {}
}
public struct DecodabilityTracker {
    public private(set) var lastGood: UInt32?
    public private(set) var ackedLTR: [UInt32] = []
    public var idrOnly: Bool
    public let maxAckedLTR: Int
    private var generation: UInt32?
    public init(idrOnly: Bool = false, maxAckedLTR: Int = 16) {
        self.idrOnly = idrOnly
        self.maxAckedLTR = max(1, maxAckedLTR)
    }
    public mutating func accept(id: UInt32, info: FrameInfo) -> Bool {
        let valid: Bool
        if info.type == .audio { return true }
        if info.type == .idr {
            valid = !info.codecConfig.isEmpty
        } else if generation != info.generation {
            valid = false
        } else {
            switch info.reference {
            case .none: valid = false
            case .previous: valid = lastGood.map { id == $0 &+ 1 } ?? false
            case .ltr: valid = !idrOnly && ackedLTR.contains(info.referenceID)
            case .ltrAny: valid = !idrOnly && !ackedLTR.isEmpty
            }
        }
        if valid {
            lastGood = id
            generation = info.generation
        } else {
            lastGood = nil
        }
        return valid
    }
    public mutating func decodedLTR(_ id: UInt32) {
        guard !ackedLTR.contains(id) else { return }
        if ackedLTR.count == maxAckedLTR { ackedLTR.removeFirst() }
        ackedLTR.append(id)
    }
    public mutating func reset() {
        lastGood = nil
        generation = nil
        ackedLTR.removeAll(keepingCapacity: true)
    }
}
/// Retains application storage and a small frame header without copying the encoded payload.
public final class StoredFrame {
    private let storage: any ByteStorage
    private let prefix: [UInt8]
    public var count: Int { prefix.count + storage.count }
    public init<Storage: ByteStorage>(storage: Storage, prefix: [UInt8]) {
        self.storage = storage
        self.prefix = prefix
    }
    public func copy(range: Range<Int>, into output: inout OutputRawSpan) throws {
        guard range.lowerBound >= 0, range.upperBound <= count, output.freeCapacity >= range.count else { throw WireError.overflow }
        if range.lowerBound < prefix.count { for i in range.lowerBound..<min(range.upperBound, prefix.count) { output.append(prefix[i], as: UInt8.self) } }
        if range.upperBound > prefix.count {
            try storage.withUnsafeBytes { bytes in
                let start = max(0, range.lowerBound - prefix.count)
                let end = range.upperBound - prefix.count
                guard end <= bytes.count else { throw WireError.malformed }
                for i in start..<end { output.append(bytes[i], as: UInt8.self) }
            }
        }
    }
}
extension Fragmenter {
    public func encode(frame: StoredFrame, stream: UInt8, frameID: UInt32, index: Int, retransmission: Bool = false, into output: inout OutputRawSpan) throws {
        let count = try fragmentCount(byteCount: frame.count)
        guard index >= 0, index < count else { throw WireError.malformed }
        let offset = index * stride
        let length = min(stride, frame.count - offset)
        try output.put(UInt8(1))
        try output.put(UInt16(16 + length))
        try FragmentHeader(stream: stream, flags: retransmission ? 2 : 0, frameID: frameID, index: UInt16(index), count: UInt16(count), stride: UInt16(stride)).encode(into: &output)
        try frame.copy(range: offset..<(offset + length), into: &output)
    }
}
extension ReassembledFrame {
    public func withPayloadBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        try withUnsafeBytes { bytes in
            var reader = ByteReader(RawSpan(_unsafeBytes: bytes))
            _ = try FrameInfo.decode(&reader)
            return try body(UnsafeRawBufferPointer(rebasing: bytes[reader.offset...]))
        }
    }
}
