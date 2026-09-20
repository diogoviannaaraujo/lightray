import LightrayPrimitives
import LightrayWire

public final class ReliableChannel {
    public struct Segment {
        public var sequence: UInt32
        public var index: UInt16
        public var count: UInt16
        public var payload: [UInt8]
        public init(sequence: UInt32, index: UInt16, count: UInt16, payload: [UInt8]) {
            self.sequence = sequence
            self.index = index
            self.count = count
            self.payload = payload
        }
    }
    private struct Outgoing {
        var segments: [Segment]
        var next: Instant
        var bytes: Int
    }
    private struct Incoming {
        var pieces: [[UInt8]?]
        var received: Int = 0
        var bytes: Int = 0
    }
    private var sendSequence: UInt32 = 0, receiveSequence: UInt32 = 0
    private var outgoing: [UInt32: Outgoing] = [:]
    private var incoming: [UInt32: Incoming] = [:]
    private var incomingBytes = 0, outgoingBytes = 0
    public let maxBytes: Int
    public init(maxBytes: Int = 4 * 1024 * 1024) { self.maxBytes = maxBytes }
    public func send(_ payload: [UInt8], maxPayload: Int, at: Instant) throws -> UInt32 {
        guard maxPayload > 0, payload.count <= maxBytes - outgoingBytes, outgoing.count < 256 else { throw WireError.overflow }
        let count = max(1, (payload.count + maxPayload - 1) / maxPayload)
        guard count <= 4096 else { throw WireError.overflow }
        let seq = sendSequence
        sendSequence &+= 1
        let segments = (0..<count).map { i in Segment(sequence: seq, index: UInt16(i), count: UInt16(count), payload: Array(payload[min(i * maxPayload, payload.count)..<min((i + 1) * maxPayload, payload.count)])) }
        outgoing[seq] = .init(segments: segments, next: at, bytes: payload.count)
        outgoingBytes += payload.count
        return seq
    }
    public func poll(at: Instant, rto: UInt64) -> [Segment] {
        var result: [Segment] = []
        for seq in outgoing.keys.sorted(by: { SerialNumber.isNewer($1, than: $0) }) {
            if let message = outgoing[seq], message.next <= at {
                result += message.segments
                outgoing[seq]?.next = at.advanced(by: max(2_000_000, rto))
            }
        }
        return result
    }
    public func acknowledge(_ sequence: UInt32) { if let message = outgoing.removeValue(forKey: sequence) { outgoingBytes -= message.bytes } }
    public func receive(_ segment: Segment) throws -> (messages: [[UInt8]], acknowledged: [UInt32]) {
        let seq = segment.sequence
        if SerialNumber.isNewer(receiveSequence, than: seq) { return ([], [seq]) }
        guard seq &- receiveSequence < 256, segment.count > 0, segment.count <= 4096, segment.index < segment.count else { throw WireError.malformed }
        if incoming[seq] == nil { incoming[seq] = .init(pieces: .init(repeating: nil, count: Int(segment.count))) }
        guard incoming[seq]!.pieces.count == Int(segment.count) else { throw WireError.malformed }
        if incoming[seq]!.pieces[Int(segment.index)] == nil {
            guard segment.payload.count <= maxBytes - incomingBytes else { throw WireError.overflow }
            incoming[seq]!.pieces[Int(segment.index)] = segment.payload
            incoming[seq]!.received += 1
            incoming[seq]!.bytes += segment.payload.count
            incomingBytes += segment.payload.count
        }
        var messages: [[UInt8]] = []
        var acknowledged: [UInt32] = []
        while let message = incoming[receiveSequence], message.received == message.pieces.count {
            messages.append(message.pieces.flatMap { $0 ?? [] })
            acknowledged.append(receiveSequence)
            incomingBytes -= message.bytes
            incoming.removeValue(forKey: receiveSequence)
            receiveSequence &+= 1
        }
        return (messages, acknowledged)
    }
    public func reset() {
        outgoing.removeAll()
        incoming.removeAll()
        incomingBytes = 0
        outgoingBytes = 0
        sendSequence = 0
        receiveSequence = 0
    }
    public var pendingCount: Int { outgoing.count }
}
