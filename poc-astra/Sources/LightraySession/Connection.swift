import LightrayCrypto

private final class MediaState {
    var feedbackBase: UInt32?
    var feedbackHighest: UInt32?
    var feedbackArrival: UInt32 = 0
    var feedbackTimes = InlineArray<512, UInt32?>(repeating: nil)
    var feedbackNeeded = false
    var feedbackDue = Instant()
    var pacer = Pacer()
    var reassembler = Reassembler()
    var nacks = NackScheduler()
    var store = RetransmitStore()
    var reliable: [UInt8: ReliableChannel] = [:]
    var trackers: [UInt8: DecodabilityTracker] = [:]
    var sentLog = SentPacketLog()
    var ready: [UInt64: (ReassembledFrame, FrameInfo)] = [:]
    var nextFrame: [UInt8: UInt32] = [:]
    var completed: [UInt8: [UInt32]] = [:]
    var decodedCandidates: [UInt8: [UInt32]] = [:]
    var lastLTRAck: [UInt8: Instant] = [:]
    var refresh: [UInt8: (id: UInt32, next: Instant)] = [:]
    var ackedLTR: [UInt8: [UInt32]] = [:]
    func channel(_ stream: UInt8) -> ReliableChannel {
        if let channel = reliable[stream] { return channel }
        let channel = ReliableChannel()
        reliable[stream] = channel
        return channel
    }
}
public final class Connection {
    public let sessionID: UInt32
    public let pairingID: UInt64
    public let role: Role
    public private(set) var peer: PeerAddress
    public private(set) var state: SessionState = .active
    public private(set) var configuration: Configuration
    public private(set) var stats = StatsSnapshot()
    public var policy: SessionPolicy
    public let streams: [StreamDescriptor]
    public let ltr: Bool
    public let token: [UInt8]
    private var sendProtection: AESGCMProtection?
    private var receiveProtection: AESGCMProtection?
    private var sendNumber: UInt64 = 1
    private var replay = ReplayWindow()
    private var media: MediaState? = MediaState()
    private var events = RingBuffer<ConnectionEvent>(capacity: 512)
    private var immediate = RingBuffer<[UInt8]>(capacity: 64)
    private var frameIDs: [UInt8: UInt32] = [:]
    private var outboundVideo: Set<UInt8> = []
    private var lastReceive: Instant
    private var lastSend: Instant
    private var lastTick: Instant
    private var parkedAt: Instant?
    private var idleEmitted = false
    private var resumeStarted: Instant?
    private var resumeNext: Instant?
    private var resumeBackoff: UInt64 = 10_000_000
    private var bitrate: BitrateController
    private var windowStarted: Instant
    private var windowReceived = 0, windowLost = 0
    private var requestID: UInt32 = 0
    private var lastFeedback: UInt32?

    public init(result: HandshakeResult, role: Role, peer: PeerAddress, at: Instant, policy: SessionPolicy = .init()) {
        sessionID = result.sessionID
        pairingID = result.pairingID
        self.role = role
        self.peer = peer
        configuration = result.configuration
        self.policy = policy
        streams = result.streams
        ltr = result.ltr
        token = result.resetToken
        if role == .client {
            self.policy.pipelineIdleAfter = result.pipelineIdleAfter
            self.policy.graceWindow = result.graceWindow
        }
        sendProtection = role == .host ? result.keys.hostToClient : result.keys.clientToHost
        receiveProtection = role == .host ? result.keys.clientToHost : result.keys.hostToClient
        lastReceive = at
        lastSend = at
        lastTick = at
        windowStarted = at
        bitrate = .init(target: result.configuration.bitrate, floor: result.configuration.bitrateFloor)
        emit(.connected)
        stats.timeline.append(.init(.connected, at: at))
    }
    private func permits(stream: UInt8, kind: StreamKind, sending: Bool) -> Bool {
        if stream == 0 { return kind == .reliable }
        guard let descriptor = streams.first(where: { $0.id == stream }), descriptor.kind == kind else { return false }
        if descriptor.direction == .bidirectional { return true }
        let hostSends = (role == .host) == sending
        return descriptor.direction == (hostSends ? .hostToClient : .clientToHost)
    }
    private func emit(_ event: ConnectionEvent) {
        if !events.append(event) {
            _ = events.popFirst()
            _ = events.append(.error("Event queue overflow; consumer must drain events"))
        }
    }
    public func pollEvent() -> ConnectionEvent? { events.popFirst() }
    public func retainedLTRAcknowledgments(stream: UInt8) -> Int { media?.ackedLTR[stream]?.count ?? 0 }
    public var parkedSince: Instant? { parkedAt }
    public var retainedMediaBytes: Int { (media?.store.byteCount ?? 0) + (media?.reassembler.allocatedBytes ?? 0) + (media?.pacer.queuedBytes ?? 0) }
    public func nextTimeout() -> Instant? { state == .active ? min(lastSend.advanced(by: policy.keepaliveInterval), lastReceive.advanced(by: policy.parkAfterSilence), resumeNext ?? .init(.max), lastTick.advanced(by: 1_000_000)) : nil }
    private func queue(_ type: UInt8, _ body: [UInt8], priority: PacketPriority = .control, at: Instant) throws {
        var w = ByteWriter()
        try w.chunk(type, body)
        guard let media else { throw WireError.malformed }
        try media.pacer.enqueue(w.bytes, priority: priority, at: at)
    }
    private func protected(_ body: [UInt8], at: Instant) throws -> [UInt8] {
        guard let sendProtection, sendNumber < .max else {
            state = .closed
            throw CryptoError.exhausted
        }
        var h = ByteWriter()
        h.put(UInt8(0))
        h.put(UInt8(0))
        h.put(UInt16(0))
        h.put(sessionID)
        h.put(UInt32(truncatingIfNeeded: sendNumber))
        h.put(at.microseconds)
        let packet = h.bytes + (try sendProtection.seal(body, header: h.bytes, packetNumber: sendNumber))
        media?.sentLog.record(number: sendNumber, at: at, bytes: packet.count)
        sendNumber += 1
        stats.path.sent += 1
        stats.path.bytesSent += UInt64(packet.count)
        lastSend = at
        return packet
    }
    public func pollTransmit(at: Instant) -> Transmit? {
        if let bytes = immediate.popFirst() { return .init(bytes: bytes, peer: peer) }
        guard state == .active, let body = media?.pacer.poll(at: at) else { return nil }
        do {
            let bytes = try protected(body, at: at)
            stats.pacerBytes = media?.pacer.queuedBytes ?? 0
            return .init(bytes: bytes, peer: peer)
        } catch {
            emit(.error(String(describing: error)))
            return nil
        }
    }
    @discardableResult public func pollTransmit(into buffer: UnsafeMutableRawBufferPointer, at: Instant) -> (count: Int, peer: PeerAddress)? {
        guard buffer.count >= Int(configuration.maxDatagramSize), let packet = pollTransmit(at: at) else { return nil }
        packet.bytes.withUnsafeBytes { buffer.copyMemory(from: $0) }
        return (packet.bytes.count, packet.peer)
    }
    @discardableResult public func submit<Storage>(_ frame: EncodedFrame<Storage>, at: Instant) throws -> UInt32 where Storage: ByteStorage {
        guard state == .active, let media else { throw WireError.malformed }
        guard permits(stream: frame.stream, kind: frame.info.type == .audio ? .audio : .video, sending: true) else { throw WireError.malformed }
        guard frame.storage.count > 0, frame.storage.count <= 8 * 1024 * 1024 else { throw WireError.overflow }
        let prefix = try frame.info.encode()
        let bytes = StoredFrame(storage: frame.storage, prefix: prefix)
        let fragmenter = try Fragmenter(maxDatagramSize: Int(configuration.maxDatagramSize))
        let count = try fragmenter.fragmentCount(byteCount: bytes.count)
        guard bytes.count + count * 19 <= media.pacer.maxQueueBytes - media.pacer.queuedBytes else { throw WireError.overflow }
        let id = frameIDs[frame.stream, default: 0]
        frameIDs[frame.stream] = id &+ 1
        if frame.info.type != .audio { outboundVideo.insert(frame.stream) }
        media.store.store(stream: frame.stream, id: id, bytes: bytes, stride: fragmenter.stride, at: at)
        media.pacer.bytesPerSecond = FrameSpreadingPolicy().rate(targetBitrate: bitrate.target, frameBytes: bytes.count, interval: 1_000_000_000 / UInt64(configuration.frameRate))
        for index in 0..<count { try enqueueFragment(bytes: bytes, stream: frame.stream, id: id, index: index, stride: fragmenter.stride, retransmission: false, priority: frame.info.type == .audio ? .audio : .video, at: at) }
        stats.streams.submitted += 1
        return id
    }
    private func enqueueFragment(bytes: StoredFrame, stream: UInt8, id: UInt32, index: Int, stride: Int, retransmission: Bool, priority: PacketPriority, at: Instant) throws {
        let fragmenter = try Fragmenter(maxDatagramSize: stride + 51)
        let chunk = try [UInt8](unsafeUninitializedCapacity: stride + 19) { buffer, initialized in
            let raw = UnsafeMutableRawBufferPointer(buffer)
            var output = OutputRawSpan(buffer: raw, initializedCount: 0)
            try fragmenter.encode(frame: bytes, stream: stream, frameID: id, index: index, retransmission: retransmission, into: &output)
            initialized = output.finalize(for: raw)
        }
        try media?.pacer.enqueue(chunk, priority: priority, at: at)
    }
    public func sendReliable(stream: UInt8, bytes: [UInt8], at: Instant) throws {
        guard permits(stream: stream, kind: .reliable, sending: true) else { throw WireError.malformed }
        guard state == .active, let media else { throw WireError.malformed }
        _ = try media.channel(stream).send(bytes, maxPayload: Int(configuration.maxDatagramSize) - 44, at: at)
    }
    public func sendDatagram(stream: UInt8, bytes: [UInt8], at: Instant) throws {
        guard permits(stream: stream, kind: .datagram, sending: true) else { throw WireError.malformed }
        guard bytes.count <= Int(configuration.maxDatagramSize) - 36 else { throw WireError.overflow }
        try queue(3, [stream] + bytes, at: at)
    }
    public func handle(datagram packet: [UInt8], from address: PeerAddress, at: Instant) {
        guard state != .closed else { return }
        if packet.count == 21, packet[0] == 0x82 {
            var r = ByteReader(packet.span.bytes)
            do {
                try r.skip(1)
                guard try r.u32() == sessionID, constantTimeEqual(try r.take(16).copyBytes(), token) else { return }
                state = .closed
                media = nil
                sendProtection = nil
                receiveProtection = nil
                emit(.sessionLost)
            } catch { stats.path.malformed += 1 }
            return
        }
        guard let receiveProtection, packet.count >= 32, packet.count <= 9000 else {
            stats.path.malformed += 1
            return
        }
        do {
            var reader = ByteReader(packet.span.bytes)
            let header = try PacketHeader.decode(&reader)
            guard header.sessionID == sessionID else { return }
            let number = replay.reconstruct(header.transportSeq)
            guard replay.accepts(number) else {
                stats.path.duplicates += 1
                return
            }
            guard let plaintext = try? receiveProtection.open(Array(packet.dropFirst(16)), header: Array(packet.prefix(16)), packetNumber: number) else {
                stats.path.authenticationFailures += 1
                return
            }
            let newest = replay.highest.map { number > $0 } ?? true
            _ = replay.commit(number)
            if !newest { stats.path.reordered += 1 }
            if address != peer {
                guard newest else { return }
                peer = address
                stats.reconnect.rebinds += 1
                stats.timeline.append(.init(.rebound, at: at))
                emit(.rebound(address))
            }
            if state == .parked {
                guard newest else { return }
                try activate(at: at)
            }
            lastReceive = at
            stats.path.received += 1
            stats.path.bytesReceived += UInt64(packet.count)
            stats.path.recordArrival(sendTime: header.sendTimeUs, at: at)
            var chunks = ByteReader(plaintext.span.bytes)
            var acknowledge = false
            while let chunk = try chunks.nextChunk() {
                if chunk.type != 0x10 && chunk.type != 0x31 { acknowledge = true }
                try handleChunk(type: chunk.type, body: chunk.body, header: header, at: at)
            }
            if state == .active { try recordFeedback(sequence: header.transportSeq, acknowledge: acknowledge, at: at) }
        } catch { stats.path.malformed += 1 }
    }
    private func handleChunk(type: UInt8, body: RawSpan, header: PacketHeader, at: Instant) throws {
        guard let media else { return }
        var r = ByteReader(body)
        switch type {
        case 1:
            let fragment = try r.fragment()
            let h = fragment.header
            guard permits(stream: h.stream, kind: .video, sending: false) || permits(stream: h.stream, kind: .audio, sending: false) else { throw WireError.malformed }
            if media.completed[h.stream, default: []].contains(h.frameID) { return }
            media.nacks.observe(stream: h.stream, frameID: h.frameID, at: at)
            if let frame = try media.reassembler.receive(fragment, at: at) {
                media.nacks.complete(stream: h.stream, frameID: h.frameID)
                var recent = media.completed[h.stream, default: []]
                if recent.count == 256 { recent.removeFirst() }
                recent.append(h.frameID)
                media.completed[h.stream] = recent
                let info = try frame.withUnsafeBytes { bytes in
                    var reader = ByteReader(RawSpan(_unsafeBytes: bytes))
                    return try FrameInfo.decode(&reader)
                }
                let key = UInt64(h.stream) << 32 | UInt64(h.frameID)
                guard media.ready.count < 128 else { throw WireError.overflow }
                if info.type == .idr || info.reference == .ltr || info.reference == .ltrAny {
                    media.ready = media.ready.filter { entry in UInt8(entry.key >> 32) != h.stream || !SerialNumber.isNewer(h.frameID, than: UInt32(truncatingIfNeeded: entry.key)) }
                }
                media.ready[key] = (frame, info)
                if media.nextFrame[h.stream] == nil || info.type == .idr || info.reference == .ltr || info.reference == .ltrAny { media.nextFrame[h.stream] = h.frameID }
                try deliverReady(stream: h.stream, at: at)
            }
        case 2:
            let stream = try r.u8()
            let seq = try r.u32()
            let index = try r.u16()
            let count = try r.u16()
            guard permits(stream: stream, kind: .reliable, sending: false) else { throw WireError.malformed }
            let result = try media.channel(stream).receive(.init(sequence: seq, index: index, count: count, payload: r.rest().copyBytes()))
            for seq in result.acknowledged {
                var ack = ByteWriter()
                ack.put(UInt32(0))
                ack.put(UInt16(0))
                ack.put(UInt32(0))
                ack.put(UInt16(1))
                ack.put(stream)
                ack.put(seq)
                try queue(0x10, ack.bytes, at: at)
            }
            for message in result.messages { if stream == 0 { try handleControl(message, at: at) } else { emit(.reliable(stream, message)) } }
        case 3:
            let stream = try r.u8()
            guard permits(stream: stream, kind: .datagram, sending: false) else { throw WireError.malformed }
            emit(.datagram(stream, r.rest().copyBytes()))
        case 0x10:
            let base = try r.u32()
            let count = Int(try r.u16())
            let baseArrival = try r.u32()
            guard count <= 4096 else { throw WireError.malformed }
            let bitmap = try r.take((count + 7) / 8)
            for i in 0..<count {
                let received = bitmap.unsafeLoad(fromUncheckedByteOffset: i / 8, as: UInt8.self) & (1 << (i % 8)) != 0
                let delta = received ? Int32(Int16(bitPattern: try r.u16())) * 4 : 0
                let seq = base &+ UInt32(i)
                if lastFeedback == nil || SerialNumber.isNewer(seq, than: lastFeedback!) {
                    lastFeedback = seq
                    if received {
                        windowReceived += 1
                    } else {
                        windowLost += 1
                        stats.path.lost += 1
                    }
                    let number = UInt64(seq)
                    if received, let sent = media.sentLog.entry(number: number) {
                        let arrival = baseArrival &+ UInt32(bitPattern: delta)
                        let hold = UInt64(header.sendTimeUs &- arrival) * 1000
                        let elapsed = at.elapsed(since: sent.at)
                        if elapsed > hold { stats.path.recordRTT(elapsed - hold) }
                    }
                }
            }
            if r.remaining > 0 {
                let acks = Int(try r.u16())
                guard acks <= 256 else { throw WireError.malformed }
                for _ in 0..<acks {
                    let stream = try r.u8()
                    let seq = try r.u32()
                    media.channel(stream).acknowledge(seq)
                }
            }
            guard r.remaining == 0 else { throw WireError.malformed }
        case 0x11:
            let stream = try r.u8()
            while r.remaining > 0 {
                let id = try r.u32()
                let first = Int(try r.u16())
                let requested = Int(try r.u16())
                guard let stored = media.store.get(stream: stream, id: id) else { continue }
                let total = (stored.bytes.count + stored.stride - 1) / stored.stride
                let end = requested == 0 ? total : min(total, first + requested)
                guard first < end else { continue }
                for index in first..<end where media.store.shouldRetransmit(stream: stream, id: id, index: UInt16(index), at: at, srtt: UInt64(stats.path.srtt)) {
                    try enqueueFragment(bytes: stored.bytes, stream: stream, id: id, index: index, stride: stored.stride, retransmission: true, priority: .retransmission, at: at)
                    stats.streams.retransmits += 1
                }
            }
        case 0x12:
            while r.remaining > 0 {
                let stream = try r.u8()
                let id = try r.u32()
                let status = try r.u8()
                if status == 1, ltr {
                    var acks = media.ackedLTR[stream, default: []]
                    if !acks.contains(id) {
                        if acks.count == 16 { acks.removeFirst() }
                        acks.append(id)
                        media.ackedLTR[stream] = acks
                    }
                }
            }
        case 0x13:
            let stream = try r.u8()
            try r.skip(1)
            let preferred = try r.u8()
            try r.skip(12)
            let acks = media.ackedLTR[stream, default: []]
            emit(.refreshRequired(stream, ltr && preferred == 0 && !acks.isEmpty ? .ltr : .idr, acks))
            stats.timeline.append(.init(.refresh, at: at))
        case 0x30: try queue(0x31, body.copyBytes(), at: at)
        case 0x31:
            if r.remaining == 8 {
                let sent = try r.u64()
                if sent <= at.nanoseconds { stats.path.recordRTT(at.nanoseconds - sent) }
            }
        case 0x32: parkLocally(at: at)
        case 0x33: try sendState(flags: 1, at: at)
        case 0x34:
            let code = try r.u16()
            state = .closed
            self.media = nil
            sendProtection = nil
            receiveProtection = nil
            emit(.closed(code))
        default: break
        }
    }
    private func deliverReady(stream: UInt8, at: Instant) throws {
        guard let media else { return }
        while let id = media.nextFrame[stream], let (frame, info) = media.ready.removeValue(forKey: UInt64(stream) << 32 | UInt64(id)) {
            media.nextFrame[stream] = id &+ 1
            var tracker = media.trackers[stream] ?? .init(idrOnly: !ltr)
            let accepted = tracker.accept(id: id, info: info)
            media.trackers[stream] = tracker
            guard accepted else {
                stats.streams.dropped += 1
                try requestRefresh(stream: stream, lost: id, at: at)
                continue
            }
            if info.ltrMark {
                var candidates = media.decodedCandidates[stream, default: []]
                if candidates.count == 256 { candidates.removeFirst() }
                candidates.append(id)
                media.decodedCandidates[stream] = candidates
            }
            media.refresh.removeValue(forKey: stream)
            stats.streams.completed += 1
            stats.streams.completionLatency.record(at.elapsed(since: frame.started))
            if let started = resumeStarted, info.type == .idr {
                stats.reconnect.resumeLatency.record(at.elapsed(since: started))
                resumeStarted = nil
            }
            emit(.frame(frame, info))
        }
    }
    private func recordFeedback(sequence: UInt32, acknowledge: Bool, at: Instant) throws {
        guard let media else { return }
        if let base = media.feedbackBase, sequence &- base >= 512 || at.microseconds &- media.feedbackArrival > 120_000 { try flushFeedback(at: at) }
        if media.feedbackBase == nil {
            media.feedbackBase = sequence
            media.feedbackArrival = at.microseconds
            media.feedbackDue = at.advanced(by: 4_000_000)
        }
        guard let base = media.feedbackBase, sequence &- base < 512 else { return }
        media.feedbackTimes[Int(sequence &- base)] = at.microseconds
        if media.feedbackHighest == nil || SerialNumber.isNewer(sequence, than: media.feedbackHighest!) { media.feedbackHighest = sequence }
        media.feedbackNeeded = media.feedbackNeeded || acknowledge
    }
    private func flushFeedback(at: Instant) throws {
        guard let media else { return }
        defer {
            media.feedbackBase = nil
            media.feedbackHighest = nil
            media.feedbackTimes = .init(repeating: nil)
            media.feedbackNeeded = false
        }
        guard media.feedbackNeeded, let base = media.feedbackBase, let highest = media.feedbackHighest else { return }
        let count = Int(highest &- base) + 1
        // Leave room for the bitmap, ACK count, chunk header, and AEAD envelope at the negotiated MTU.
        let maxCount = max(1, (Int(configuration.maxDatagramSize) - 47) * 8 / 17)
        var start = 0
        while start < count {
            let end = min(count, start + maxCount)
            var w = ByteWriter()
            w.put(base &+ UInt32(start))
            w.put(UInt16(end - start))
            w.put(media.feedbackArrival)
            var bitmap = [UInt8](repeating: 0, count: (end - start + 7) / 8)
            for i in start..<end where media.feedbackTimes[i] != nil { bitmap[(i - start) / 8] |= 1 << ((i - start) % 8) }
            w.bytes += bitmap
            for i in start..<end { if let time = media.feedbackTimes[i] { w.put(Int16(clamping: Int32(bitPattern: time &- media.feedbackArrival) / 4)) } }
            w.put(UInt16(0))
            try queue(0x10, w.bytes, at: at)
            start = end
        }
    }
    public func reportDecoded(stream: UInt8, frameID: UInt32, at: Instant) throws {
        guard ltr, let media, media.decodedCandidates[stream, default: []].contains(frameID) else { return }
        if let previous = media.lastLTRAck[stream], at.elapsed(since: previous) < policy.ltrAckInterval { return }
        media.lastLTRAck[stream] = at
        stats.streams.frameAcksSent += 1
        media.trackers[stream]?.decodedLTR(frameID)
        var w = ByteWriter()
        w.put(stream)
        w.put(frameID)
        w.put(UInt8(1))
        try queue(0x12, w.bytes, at: at)
    }
    public func decoderReset(stream: UInt8, at: Instant) throws {
        media?.trackers[stream]?.reset()
        try requestRefresh(stream: stream, lost: 0, at: at, forceIDR: true)
    }
    private func requestRefresh(stream: UInt8, lost: UInt32, at: Instant, forceIDR: Bool = false) throws {
        guard let media else { return }
        var w = ByteWriter()
        w.put(stream)
        w.put(UInt8(forceIDR ? 1 : 0))
        w.put(UInt8(!forceIDR && ltr && !(media.trackers[stream]?.ackedLTR.isEmpty ?? true) ? 0 : 1))
        w.put(media.trackers[stream]?.lastGood ?? 0)
        w.put(lost)
        w.put(requestID)
        requestID &+= 1
        try queue(0x13, w.bytes, at: at)
        media.refresh[stream] = (lost, at.advanced(by: 20_000_000))
    }
    private func parkLocally(at: Instant) {
        guard state == .active else { return }
        state = .parked
        media = nil
        events = RingBuffer(capacity: 8)
        parkedAt = at
        idleEmitted = false
        stats.pacerBytes = 0
        stats.reconnect.parks += 1
        stats.timeline.append(.init(.parked, at: at))
        emit(.parked)
    }
    public func park(at: Instant) throws {
        guard state == .active else { return }
        var w = ByteWriter()
        try w.chunk(0x32, [])
        let packet = try protected(w.bytes, at: at)
        _ = immediate.append(packet)
        parkLocally(at: at)
    }
    private func activate(at: Instant) throws {
        state = .active
        media = MediaState()
        events = RingBuffer(capacity: 512)
        parkedAt = nil
        lastReceive = at
        lastSend = at
        stats.reconnect.resumes += 1
        stats.timeline.append(.init(.resumed, at: at))
        emit(.resumed)
        try sendState(flags: 1, at: at)
        for stream in outboundVideo { emit(.refreshRequired(stream, .idr, [])) }
    }
    public func resume(decoderLost: Bool = true, at: Instant) throws {
        guard state != .closed else { throw WireError.malformed }
        if state == .parked {
            try activate(at: at)
        } else {
            media?.pacer.removeAll()
            media?.nacks.removeAll()
            media?.reassembler.removeAll()
            if decoderLost { media?.trackers.removeAll() }
        }
        resumeStarted = at
        resumeNext = at
        resumeBackoff = 10_000_000
        try queue(0x33, [decoderLost ? 1 : 0], at: at)
    }
    public func reconfigure(_ config: Configuration, at: Instant) throws {
        _ = try config.validated()
        requestID &+= 1
        var w = ByteWriter()
        w.put(UInt8(1))
        w.put(requestID)
        w.put(UInt8(255))
        w.bytes += config.encode()
        try sendReliable(stream: 0, bytes: w.bytes, at: at)
    }
    private func sendState(flags: UInt8, at: Instant) throws {
        var w = ByteWriter()
        w.put(UInt8(3))
        w.put(flags)
        w.put(configuration.generation)
        w.bytes += configuration.encode()
        try sendReliable(stream: 0, bytes: w.bytes, at: at)
    }
    private func handleControl(_ bytes: [UInt8], at: Instant) throws {
        var r = ByteReader(bytes.span.bytes)
        let type = try r.u8()
        switch type {
        case 1:
            let request = try r.u32()
            let scope = try r.u8()
            var proposed: Configuration?
            do {
                guard scope == 255 else { throw WireError.malformed }
                proposed = try Configuration.decode(r.rest(), base: configuration)
            } catch { proposed = nil }
            if var config = proposed {
                config.generation = configuration.generation &+ 1
                let refresh = config.width != configuration.width || config.height != configuration.height || config.hdr != configuration.hdr
                configuration = config
                bitrate.floor = config.bitrateFloor
                bitrate.setTarget(config.bitrate)
                stats.backstop = false
                emit(.configurationChanged(config))
                if refresh { for stream in outboundVideo { emit(.refreshRequired(stream, .idr, [])) } }
            }
            var w = ByteWriter()
            w.put(UInt8(2))
            w.put(request)
            w.put(UInt8(proposed == nil ? 1 : 0))
            w.put(configuration.generation)
            w.bytes += configuration.encode()
            try sendReliable(stream: 0, bytes: w.bytes, at: at)
        case 2:
            let request = try r.u32()
            let status = try r.u8()
            let generation = try r.u32()
            let applied = try Configuration.decode(r.rest(), base: configuration)
            if status == 0 {
                configuration = applied
                configuration.generation = generation
                emit(.configurationChanged(configuration))
            } else {
                emit(.reconfigureRejected(request))
            }
        case 3:
            let flags = try r.u8()
            let generation = try r.u32()
            configuration = try Configuration.decode(r.rest())
            configuration.generation = generation
            stats.backstop = flags & 2 != 0
            if flags & 1 != 0 { resumeNext = nil }
            emit(.configurationChanged(configuration))
        default: break
        }
    }
    public func handleTimeout(at: Instant) {
        lastTick = at
        guard state == .active, let media else { return }
        do {
            if role == .host, at.elapsed(since: lastReceive) >= policy.parkAfterSilence {
                parkLocally(at: at)
                return
            }
            if media.feedbackNeeded, at >= media.feedbackDue { try flushFeedback(at: at) }
            if let next = resumeNext, at >= next {
                try queue(0x33, [1], at: at)
                resumeNext = at.advanced(by: resumeBackoff)
                resumeBackoff = min(1_000_000_000, resumeBackoff * 2)
            }
            if at.elapsed(since: lastSend) >= policy.keepaliveInterval {
                var w = ByteWriter()
                w.put(at.nanoseconds)
                try queue(0x30, w.bytes, at: at)
            }
            for (stream, channel) in media.reliable {
                for segment in channel.poll(at: at, rto: UInt64(stats.path.srtt + 4 * stats.path.rttvar)) {
                    var w = ByteWriter()
                    w.put(stream)
                    w.put(segment.sequence)
                    w.put(segment.index)
                    w.put(segment.count)
                    w.bytes += segment.payload
                    try queue(2, w.bytes, at: at)
                }
            }
            let pending = media.nacks.poll(at: at, srtt: UInt64(stats.path.srtt))
            for (stream, id) in pending.nacks {
                for entry in media.reassembler.missing(stream: stream, frameID: id, at: at, tailWait: 1_000_000_000 / UInt64(configuration.frameRate)) {
                    var w = ByteWriter()
                    w.put(stream)
                    w.put(entry.frameID)
                    w.put(entry.first)
                    w.put(entry.count)
                    try queue(0x11, w.bytes, at: at)
                    stats.streams.nacks += 1
                }
            }
            for (stream, id) in pending.expired {
                media.reassembler.discard(stream: stream, frameID: id)
                stats.streams.dropped += 1
                if media.nextFrame[stream] == id {
                    media.nextFrame[stream] = id &+ 1
                    try deliverReady(stream: stream, at: at)
                }
                try requestRefresh(stream: stream, lost: id, at: at)
            }
            for (stream, request) in media.refresh where at >= request.next { try requestRefresh(stream: stream, lost: request.id, at: at) }
            media.store.expire(at: at)
            if at.elapsed(since: windowStarted) >= 500_000_000 {
                if bitrate.recordWindow(received: windowReceived, lost: windowLost) {
                    configuration.bitrate = bitrate.target
                    stats.backstop = true
                    emit(.bitrateChanged(bitrate.target))
                    try sendState(flags: 2, at: at)
                }
                windowStarted = at
                windowReceived = 0
                windowLost = 0
            }
            stats.bitrate = bitrate.target
            stats.pacerBytes = media.pacer.queuedBytes
        } catch { emit(.error(String(describing: error))) }
    }
    public func sweepParked(at: Instant) {
        guard state == .parked, let parkedAt else { return }
        if at.elapsed(since: parkedAt) >= policy.graceWindow {
            state = .closed
            sendProtection = nil
            receiveProtection = nil
            emit(.expired)
            stats.timeline.append(.init(.expired, at: at))
        } else if !idleEmitted, at.elapsed(since: parkedAt) >= policy.pipelineIdleAfter {
            idleEmitted = true
            emit(.idle)
            stats.timeline.append(.init(.idle, at: at))
        }
    }
    public func close(code: UInt16 = 0, at: Instant) throws {
        guard state != .closed else { return }
        var body = ByteWriter()
        body.put(code)
        var w = ByteWriter()
        try w.chunk(0x34, body.bytes)
        _ = immediate.append(try protected(w.bytes, at: at))
        state = .closed
        media = nil
        sendProtection = nil
        receiveProtection = nil
        emit(.closed(code))
    }
}
