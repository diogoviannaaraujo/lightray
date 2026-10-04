/// Chunk types, `docs/registries.md#chunk-types`.
public enum ChunkType {
    public static let padding: UInt8 = 0x00
    public static let mediaFragment: UInt8 = 0x01
    public static let reliable: UInt8 = 0x02
    public static let datagram: UInt8 = 0x03
    public static let feedback: UInt8 = 0x10
    public static let nack: UInt8 = 0x11
    public static let frameAck: UInt8 = 0x12
    public static let refreshRequest: UInt8 = 0x13
    public static let ping: UInt8 = 0x30
    public static let pong: UInt8 = 0x31
    public static let park: UInt8 = 0x32
    public static let resume: UInt8 = 0x33
    public static let close: UInt8 = 0x34
}

/// Close codes, `docs/registries.md#close-codes`. An unassigned code reads as `normal`.
public enum CloseCode: UInt16, Sendable {
    case normal = 0, appRequest = 1, timeout = 2, protocolViolation = 3, versionMismatch = 4, goingAway = 5
}

// MARK: - MEDIA_FRAGMENT

/// `docs/video.md#media_fragment-0x01`, version 0 text, with FEC scheme 1 in the provisional
/// form `macos/README.md` gives: scheme `NONE`, or Reed–Solomon with its parameters on every
/// fragment of the frame and parity fragments flagged `PARITY`.
public struct MediaFragment: Equatable, Sendable {
    public enum Flag {
        public static let keyframe: UInt8 = 1 << 0
        public static let retransmission: UInt8 = 1 << 1
        public static let frameStart: UInt8 = 1 << 2
        /// Provisional: a Reed–Solomon parity fragment; `index` counts parity fragments.
        public static let parity: UInt8 = 1 << 3
    }

    /// FEC scheme 1 (provisional): the longest block the frame's data fragments were split into
    /// (RFC 5052 §9.1 blocking), the parity fragments each block has, and the true length of the
    /// frame's last data fragment, so that a rebuilt one can be cut back to it.
    public struct FEC: Equatable, Sendable {
        public var maxBlockLength: UInt8
        public var parityPerBlock: UInt8
        public var lastLength: UInt16

        public init(maxBlockLength: UInt8, parityPerBlock: UInt8, lastLength: UInt16) {
            self.maxBlockLength = maxBlockLength
            self.parityPerBlock = parityPerBlock
            self.lastLength = lastLength
        }
    }

    /// Fragment header, FEC TLV and chunk header.
    public static let headerLength = 13
    static let noFEC: Bytes = [0x01, 0x01, 0x00]
    static let reedSolomonExtensionLength = 7
    /// Protected header, chunk header, fragment header, FEC TLV and tag: `stride = mds − 51`.
    public static let datagramOverhead = Packet.overhead + 3 + headerLength + noFEC.count

    /// 4 bytes more with Reed–Solomon's parameters in the FEC TLV: `stride = mds − 55`.
    public static func datagramOverhead(fec: Bool) -> Int {
        datagramOverhead + (fec ? reedSolomonExtensionLength - noFEC.count : 0)
    }

    public static func stride(forDatagramSize size: Int, fec: Bool = false) -> Int {
        size - datagramOverhead(fec: fec)
    }

    public var stream: UInt8
    public var flags: UInt8
    public var frameID: UInt32
    public var index: UInt16
    public var count: UInt16
    public var stride: UInt16
    public var fec: FEC?
    public var payload: ArraySlice<UInt8>

    public init(
        stream: UInt8, flags: UInt8, frameID: UInt32, index: UInt16, count: UInt16, stride: UInt16, fec: FEC? = nil,
        payload: ArraySlice<UInt8>
    ) {
        self.stream = stream
        self.flags = flags
        self.frameID = frameID
        self.index = index
        self.count = count
        self.stride = stride
        self.fec = fec
        self.payload = payload
    }

    public var isParity: Bool { flags & Flag.parity != 0 }

    private var fecExtension: Bytes {
        guard let fec else { return Self.noFEC }
        return [0x01, 0x05, 0x01, fec.maxBlockLength, fec.parityPerBlock, UInt8(fec.lastLength >> 8), UInt8(fec.lastLength & 0xff)]
    }

    public func write(to w: inout ByteWriter) {
        let fecExtension = fecExtension
        w.u8(ChunkType.mediaFragment)
        w.u16(UInt16(Self.headerLength + fecExtension.count + payload.count))
        w.u8(stream)
        w.u8(flags)
        w.u32(frameID)
        w.u16(index)
        w.u16(count)
        w.u16(stride)
        w.u8(UInt8(fecExtension.count))
        w.append(fecExtension)
        w.append(payload)
    }

    /// Parses a body and applies the validation table; nil discards the fragment.
    static func parse(_ body: ArraySlice<UInt8>) -> MediaFragment? {
        var r = ByteReader(body)
        guard let stream = try? r.u8(), let flags = try? r.u8(), let frameID = try? r.u32(),
            let index = try? r.u16(), let count = try? r.u16(), let stride = try? r.u16(),
            let extLength = try? r.u8(), let ext = try? r.take(Int(extLength))
        else { return nil }
        // Extension TLVs have a one-byte length. Type 1 names the FEC scheme: NONE, or
        // Reed–Solomon with its three parameters; any other scheme discards the fragment.
        var fec: FEC?
        var e = ByteReader(ext)
        while !e.isAtEnd {
            guard let type = try? e.u8(), let length = try? e.u8(), let value = try? e.take(Int(length)) else {
                return nil
            }
            guard type == 1 else { continue }
            switch (value.first, value.count) {
            case (0, _):
                fec = nil
            case (1, 5):
                let v = Array(value)
                fec = FEC(maxBlockLength: v[1], parityPerBlock: v[2], lastLength: UInt16(v[3]) << 8 | UInt16(v[4]))
            default:
                return nil
            }
        }
        let payload = r.rest()
        guard count > 0, stride > 0, !payload.isEmpty, payload.count <= Int(stride) else { return nil }
        if let fec {
            guard fec.lastLength > 0, fec.lastLength <= stride else { return nil }
        }
        if flags & Flag.parity != 0 {
            // Parity is always a whole stride, and there is one set per block.
            guard let fec,
                let layout = FECLayout(
                    dataCount: Int(count), maxBlockLength: Int(fec.maxBlockLength), parityPerBlock: Int(fec.parityPerBlock)),
                Int(index) < layout.parityCount, payload.count == Int(stride)
            else { return nil }
        } else {
            guard index < count, index == count - 1 || payload.count == Int(stride) else { return nil }
            if let fec {
                guard FECLayout(
                    dataCount: Int(count), maxBlockLength: Int(fec.maxBlockLength), parityPerBlock: Int(fec.parityPerBlock)) != nil,
                    index != count - 1 || payload.count == Int(fec.lastLength)
                else { return nil }
            }
        }
        return MediaFragment(
            stream: stream, flags: flags, frameID: frameID, index: index, count: count, stride: stride, fec: fec,
            payload: payload)
    }
}

// MARK: - RELIABLE and DATAGRAM

/// `docs/input.md#reliable-0x02`.
public struct ReliableSegment: Equatable, Sendable {
    public static let headerLength = 9

    public var stream: UInt8
    public var msgSeq: UInt32
    public var segIndex: UInt16
    public var segCount: UInt16
    public var payload: Bytes

    public init(stream: UInt8, msgSeq: UInt32, segIndex: UInt16, segCount: UInt16, payload: Bytes) {
        self.stream = stream
        self.msgSeq = msgSeq
        self.segIndex = segIndex
        self.segCount = segCount
        self.payload = payload
    }

    public func write(to w: inout ByteWriter) {
        w.u8(ChunkType.reliable)
        w.u16(UInt16(Self.headerLength + payload.count))
        w.u8(stream)
        w.u32(msgSeq)
        w.u16(segIndex)
        w.u16(segCount)
        w.append(payload)
    }

    static func parse(_ body: ArraySlice<UInt8>) -> ReliableSegment? {
        var r = ByteReader(body)
        guard let stream = try? r.u8(), let seq = try? r.u32(), let index = try? r.u16(), let count = try? r.u16(),
            count > 0, index < count
        else { return nil }
        return ReliableSegment(stream: stream, msgSeq: seq, segIndex: index, segCount: count, payload: Bytes(r.rest()))
    }
}

// MARK: - FEEDBACK

public struct ReliableAck: Hashable, Sendable {
    public var stream: UInt8
    public var msgSeq: UInt32

    public init(stream: UInt8, msgSeq: UInt32) {
        self.stream = stream
        self.msgSeq = msgSeq
    }
}

/// `docs/feedback.md#feedback-0x10`: an MSB-first bitmap of arrivals, chained arrival deltas in
/// 4 µs units, and an acknowledgement trailer.
public struct Feedback: Equatable, Sendable {
    public static let maxAcks = 256

    public var baseSeq: UInt32
    public var received: [Bool]
    public var baseArrival: UInt32
    public var deltas: [Int16]
    public var acks: [ReliableAck]

    public init(baseSeq: UInt32, received: [Bool], baseArrival: UInt32, deltas: [Int16], acks: [ReliableAck]) {
        self.baseSeq = baseSeq
        self.received = received
        self.baseArrival = baseArrival
        self.deltas = deltas
        self.acks = acks
    }

    /// Builds a report of `count` consecutive packet numbers from `baseSeq`, given the arrivals
    /// (offset from `baseSeq`, local arrival time) in ascending offset order. Each delta is
    /// measured from the previous arrival as the receiver of the report will reconstruct it,
    /// and clamped before scaling, so rounding never accumulates.
    public init(baseSeq: UInt32, count: Int, arrivals: [(offset: Int, time: UInt32)], acks: [ReliableAck]) {
        var received = [Bool](repeating: false, count: count)
        var deltas: [Int16] = []
        deltas.reserveCapacity(arrivals.count)
        let base = arrivals.first?.time ?? 0
        var previous = base
        for (i, arrival) in arrivals.enumerated() {
            received[arrival.offset] = true
            if i == 0 {
                deltas.append(0)
                continue
            }
            let units = (wrappingDifference(arrival.time, previous) + 2) >> 2
            let clamped = Int16(clamping: units)
            deltas.append(clamped)
            previous = previous &+ UInt32(bitPattern: Int32(clamped) * 4)
        }
        self.init(baseSeq: baseSeq, received: received, baseArrival: base, deltas: deltas, acks: acks)
    }

    /// The reported arrivals: sequence number and the reporter's clock.
    public var arrivals: [(seq: UInt32, time: UInt32)] {
        var result: [(UInt32, UInt32)] = []
        var time = baseArrival
        var k = 0
        for (i, bit) in received.enumerated() where bit {
            if k > 0 { time = time &+ UInt32(bitPattern: Int32(deltas[k]) * 4) }
            result.append((baseSeq &+ UInt32(i), time))
            k += 1
        }
        return result
    }

    public func write(to w: inout ByteWriter) {
        precondition(acks.count <= Self.maxAcks && received.count <= Int(UInt16.max))
        w.u8(ChunkType.feedback)
        let lengthOffset = w.count
        w.u16(0)
        let start = w.count
        w.u32(baseSeq)
        w.u16(UInt16(received.count))
        w.u32(baseArrival)
        var byte: UInt8 = 0
        for (i, bit) in received.enumerated() {
            if bit { byte |= 0x80 >> UInt8(i % 8) }
            if i % 8 == 7 {
                w.u8(byte)
                byte = 0
            }
        }
        if received.count % 8 != 0 { w.u8(byte) }
        for delta in deltas { w.i16(delta) }
        w.u16(UInt16(acks.count))
        for ack in acks {
            w.u8(ack.stream)
            w.u32(ack.msgSeq)
        }
        w.patchU16(at: lengthOffset, UInt16(w.count - start))
    }

    static func parse(_ body: ArraySlice<UInt8>) -> Feedback? {
        var r = ByteReader(body)
        guard let baseSeq = try? r.u32(), let count = try? r.u16(), let baseArrival = try? r.u32(),
            let bitmap = try? r.take((Int(count) + 7) / 8)
        else { return nil }
        var received = [Bool](repeating: false, count: Int(count))
        var set = 0
        for i in 0..<Int(count) where bitmap[bitmap.startIndex + i / 8] & (0x80 >> UInt8(i % 8)) != 0 {
            received[i] = true
            set += 1
        }
        var deltas: [Int16] = []
        deltas.reserveCapacity(set)
        for _ in 0..<set {
            guard let delta = try? r.i16() else { return nil }
            deltas.append(delta)
        }
        guard let ackCount = try? r.u16(), ackCount <= Self.maxAcks else { return nil }
        var acks: [ReliableAck] = []
        for _ in 0..<ackCount {
            guard let stream = try? r.u8(), let seq = try? r.u32() else { return nil }
            acks.append(ReliableAck(stream: stream, msgSeq: seq))
        }
        guard r.isAtEnd else { return nil }
        return Feedback(baseSeq: baseSeq, received: received, baseArrival: baseArrival, deltas: deltas, acks: acks)
    }
}

// MARK: - NACK, FRAME_ACK, REFRESH_REQUEST

/// `docs/feedback.md#nack-0x11`. `count = 0` asks for the whole frame.
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

public struct Nack: Equatable, Sendable {
    public static let entryLength = 8

    public var stream: UInt8
    public var entries: [NackEntry]

    public init(stream: UInt8, entries: [NackEntry]) {
        self.stream = stream
        self.entries = entries
    }

    public func write(to w: inout ByteWriter) {
        w.u8(ChunkType.nack)
        w.u16(UInt16(1 + Self.entryLength * entries.count))
        w.u8(stream)
        for entry in entries {
            w.u32(entry.frameID)
            w.u16(entry.first)
            w.u16(entry.count)
        }
    }

    static func parse(_ body: ArraySlice<UInt8>) -> Nack? {
        var r = ByteReader(body)
        guard let stream = try? r.u8(), r.remaining % entryLength == 0 else { return nil }
        var entries: [NackEntry] = []
        while !r.isAtEnd {
            entries.append(NackEntry(frameID: try! r.u32(), first: try! r.u16(), count: try! r.u16()))
        }
        return Nack(stream: stream, entries: entries)
    }
}

public struct FrameAckEntry: Equatable, Sendable {
    public var stream: UInt8
    public var frameID: UInt32
    public var status: UInt8
}

/// `docs/feedback.md#refresh_request-0x13`.
public struct RefreshRequest: Equatable, Sendable {
    public enum Reason: UInt8, Sendable { case loss = 0, decoderReset = 1, resume = 2 }
    public enum Preferred: UInt8, Sendable { case ltr = 0, idr = 1 }

    public var stream: UInt8
    public var reason: Reason
    public var preferred: Preferred
    public var lastGoodFrame: UInt32
    public var lostFrame: UInt32
    public var reqID: UInt32

    public init(
        stream: UInt8, reason: Reason, preferred: Preferred, lastGoodFrame: UInt32, lostFrame: UInt32, reqID: UInt32
    ) {
        self.stream = stream
        self.reason = reason
        self.preferred = preferred
        self.lastGoodFrame = lastGoodFrame
        self.lostFrame = lostFrame
        self.reqID = reqID
    }

    public func write(to w: inout ByteWriter) {
        w.u8(ChunkType.refreshRequest)
        w.u16(15)
        w.u8(stream)
        w.u8(reason.rawValue)
        w.u8(preferred.rawValue)
        w.u32(lastGoodFrame)
        w.u32(lostFrame)
        w.u32(reqID)
    }

    static func parse(_ body: ArraySlice<UInt8>) -> RefreshRequest? {
        var r = ByteReader(body)
        guard body.count == 15, let stream = try? r.u8(), let reason = Reason(rawValue: try! r.u8()),
            let preferred = Preferred(rawValue: try! r.u8())
        else { return nil }
        return RefreshRequest(
            stream: stream, reason: reason, preferred: preferred, lastGoodFrame: try! r.u32(),
            lostFrame: try! r.u32(), reqID: try! r.u32())
    }
}

// MARK: - Chunks

public enum Chunk: Equatable, Sendable {
    case padding
    case mediaFragment(MediaFragment)
    case reliable(ReliableSegment)
    case datagram(stream: UInt8, payload: Bytes)
    case feedback(Feedback)
    case nack(Nack)
    case frameAck([FrameAckEntry])
    case refreshRequest(RefreshRequest)
    case ping(id: UInt32)
    case pong(id: UInt32, holdMicros: UInt32)
    case close(CloseCode)
    /// A type this implementation does not handle, skipped by its length.
    case unknown(type: UInt8)

    public func write(to w: inout ByteWriter) {
        switch self {
        case .padding: w.tlv(ChunkType.padding, [UInt8]())
        case .mediaFragment(let f): f.write(to: &w)
        case .reliable(let s): s.write(to: &w)
        case .datagram(let stream, let payload): w.tlv(ChunkType.datagram, [stream] + payload)
        case .feedback(let f): f.write(to: &w)
        case .nack(let n): n.write(to: &w)
        case .frameAck(let entries):
            w.tlv(ChunkType.frameAck, entries.flatMap { e -> Bytes in
                var v = ByteWriter()
                v.u8(e.stream)
                v.u32(e.frameID)
                v.u8(e.status)
                return v.bytes
            })
        case .refreshRequest(let r): r.write(to: &w)
        case .ping(let id):
            var v = ByteWriter()
            v.u32(id)
            w.tlv(ChunkType.ping, v.bytes)
        case .pong(let id, let hold):
            var v = ByteWriter()
            v.u32(id)
            v.u32(hold)
            w.tlv(ChunkType.pong, v.bytes)
        case .close(let code):
            var v = ByteWriter()
            v.u16(code.rawValue)
            w.tlv(ChunkType.close, v.bytes)
        case .unknown: break
        }
    }

    public var encoded: Bytes {
        var w = ByteWriter()
        write(to: &w)
        return w.bytes
    }

    public struct Parsed: Sendable {
        public var chunks: [Chunk] = []
        /// Chunks whose header was sound and whose body was not; each was discarded alone.
        public var malformed = 0
    }

    /// Parses a decrypted body, `docs/packets.md#parsing-rules`: stop when fewer than 3 bytes
    /// remain or a length overruns, skip unknown types, and discard a malformed body alone.
    public static func parse(_ body: Bytes) -> Parsed {
        var result = Parsed()
        var r = ByteReader(body)
        while r.remaining >= 3 {
            let type = try! r.u8()
            let length = Int(try! r.u16())
            guard let value = try? r.take(length) else { break }
            if let chunk = parseBody(type: type, value) {
                result.chunks.append(chunk)
            } else {
                result.malformed += 1
            }
        }
        return result
    }

    static func parseBody(type: UInt8, _ value: ArraySlice<UInt8>) -> Chunk? {
        var r = ByteReader(value)
        switch type {
        case ChunkType.padding: return .padding
        case ChunkType.mediaFragment: return MediaFragment.parse(value).map(Chunk.mediaFragment)
        case ChunkType.reliable: return ReliableSegment.parse(value).map(Chunk.reliable)
        case ChunkType.datagram:
            guard let stream = try? r.u8() else { return nil }
            return .datagram(stream: stream, payload: Bytes(r.rest()))
        case ChunkType.feedback: return Feedback.parse(value).map(Chunk.feedback)
        case ChunkType.nack: return Nack.parse(value).map(Chunk.nack)
        case ChunkType.frameAck:
            guard value.count % 6 == 0 else { return nil }
            var entries: [FrameAckEntry] = []
            while !r.isAtEnd {
                entries.append(FrameAckEntry(stream: try! r.u8(), frameID: try! r.u32(), status: try! r.u8()))
            }
            return .frameAck(entries)
        case ChunkType.refreshRequest: return RefreshRequest.parse(value).map(Chunk.refreshRequest)
        case ChunkType.ping:
            guard value.count == 4 else { return nil }
            return .ping(id: try! r.u32())
        case ChunkType.pong:
            guard value.count == 8 else { return nil }
            return .pong(id: try! r.u32(), holdMicros: try! r.u32())
        case ChunkType.close:
            guard let code = try? r.u16() else { return nil }
            return .close(CloseCode(rawValue: code) ?? .normal)
        default:
            return .unknown(type: type)
        }
    }
}
