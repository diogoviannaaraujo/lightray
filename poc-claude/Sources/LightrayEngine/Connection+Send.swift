import LightrayCore
import LightrayCrypto

// The send path: frame submission, the pacer's priority order, and packet
// assembly. Media fragments never share a datagram with anything else, because
// every non-last fragment must carry exactly `stride` bytes.

extension Connection {

    // MARK: - App commands

    /// Submits an encoded frame.
    ///
    /// `frame_id` is assigned here, and only for frames that produced bytes: a
    /// low-latency encoder under a tight budget skips frames and emits nothing,
    /// so an id assigned per capture would leave gaps indistinguishable from
    /// whole-frame loss. Capture cadence stays visible in `capture_time_us`.
    public func submit(_ frame: EncodedFrame, at now: Instant) {
        guard state == .established else { return }
        guard let descriptor = streamTable.first(where: { $0.id == frame.stream }), isOutbound(descriptor)
        else { return }
        guard frame.storage.bytes.count > 0 || frame.codecConfig != nil else { return }

        let id = nextFrameID[frame.stream] ?? 1
        nextFrameID[frame.stream] = id &+ 1

        var header = FrameHeader(frameType: frame.frameType, refKind: frame.refKind,
                                 flags: frame.ltrMark ? [.ltrMark] : [],
                                 configGeneration: config.generation,
                                 captureTimeMicros: frame.captureTimeMicros,
                                 refFrameID: frame.refFrameID)
        header.codecConfigLength = frame.codecConfig?.count ?? 0

        let headerBuffer = pool.takeLarge(max(header.encodedSize, 64))
        var hw = ByteWriter(headerBuffer)
        do {
            if let cfg = frame.codecConfig {
                try cfg.withUnsafeBytes { raw in
                    try header.encode(into: &hw, codecConfig: raw)
                }
            } else {
                try header.encode(into: &hw, codecConfig: nil)
            }
        } catch {
            pool.giveBackLarge(headerBuffer)
            return
        }

        let stride = Wire.maxFragmentPayload(maxDatagramSize: maxDatagramSize)
        var flags: FragmentFlags = []
        if frame.frameType == .idr { flags.insert(.keyframe) }
        let deadline = now + Interval(nanos: config.frameInterval.nanos * engine.frameDeadlineIntervals)

        let send = SendFrame(stream: frame.stream, frameID: id, storage: frame.storage,
                             headerBuffer: headerBuffer, headerLength: hw.written,
                             stride: stride, flags: flags, submittedAt: now, deadline: deadline,
                             ltrMarked: frame.ltrMark, pool: pool)

        if descriptor.kind == .audio || descriptor.kind == .mic {
            queues.audio.append(send)
        } else {
            queues.video.append(send)
        }
        retransmits.insert(send)
        retransmits.trim(now: now)

        updatePacingRate()
        streamStats(frame.stream).framesSubmitted &+= 1
    }

    public func sendReliable(_ bytes: [UInt8], stream: UInt8 = 0) {
        let maxSegment = Wire.maxChunkSpace(maxDatagramSize: maxDatagramSize)
            - Wire.chunkHeaderSize - 9
        if reliable[stream] == nil { reliable[stream] = ReliableChannel(stream: stream) }
        reliable[stream]?.send(bytes, maxSegmentBytes: max(1, maxSegment))
    }

    public func sendDatagram(_ bytes: [UInt8], stream: UInt8) {
        pendingDatagrams.append((stream, bytes))
    }

    /// Sends a RECONFIGURE on the control channel and returns its request id.
    @discardableResult
    public func reconfigure(_ body: ControlBody) -> UInt32 {
        var body = body
        body.reqID = nextReconfigureReqID
        nextReconfigureReqID &+= 1
        if let bps = body.bitrate { bitrate.setManualTarget(bps, floor: body.bitrateFloor) }
        sendReliable(encodeControl(body))
        return body.reqID
    }

    func encodeControl(_ body: ControlBody) -> [UInt8] {
        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: 512, alignment: 16)
        defer { scratch.deallocate() }
        var w = ByteWriter(scratch)
        guard (try? body.encode(into: &w)) != nil else { return [] }
        return Array(w.contents)
    }

    /// Sends STATE with the current configuration. A resume sends this first,
    /// before anything else, so the client knows what it is resuming into.
    func sendState(flags: StateFlags) {
        sendReliable(encodeControl(ControlBody.state(config: config, flags: flags)))
    }

    // MARK: - Transmit

    /// Builds at most one datagram. Priority order is control, then
    /// retransmissions, then audio, then video; only the last three are paced.
    public func pollTransmit(into buf: UnsafeMutableRawBufferPointer, at now: Instant) -> Outgoing? {
        guard state != .closed else { return nil }
        let mds = min(maxDatagramSize, buf.count)
        guard mds >= Wire.minProtectedSize + Wire.chunkHeaderSize else { return nil }
        let chunkSpace = Wire.maxChunkSpace(maxDatagramSize: mds)
        pacer.refill(at: now)

        var w = ByteWriter(plaintextScratch)
        pendingReliableSeq = nil
        if writeControlChunks(into: &w, at: now, space: chunkSpace) {
            // If the datagram carries a reliable segment, record that rather than
            // a bare `.control`, so the FEEDBACK that reports this packet acks the
            // segment too.
            let payload: SentPacket.Payload = pendingReliableSeq.map {
                .reliable(stream: $0.stream, msgSeq: $0.msgSeq, segIndex: $0.segIndex)
            } ?? .control
            let out = finish(chunkBytes: w.written, into: buf, at: now, payload: payload)
            if out != nil { pacer.takeUnconditionally(Wire.headerSize + w.written + Wire.tagSize) }
            if let code = closeSentCode { state = .closed; push(.closed(code)); closeSentCode = nil }
            return out
        }

        // A parked or idle session sends nothing but control.
        guard state == .established else { return nil }

        // Retransmissions come before new data: a NACKed fragment is already late.
        while let (frame, index) = queues.retransmissions.first {
            _ = queues.retransmissions.pop()
            guard Int(index) < frame.fragmentCount else { continue }
            let cost = datagramCost(payload: frame.payloadLength(of: Int(index)))
            guard pacer.take(cost) else {
                queues.retransmissions.push((frame, index))
                return nil
            }
            var rw = ByteWriter(plaintextScratch)
            guard writeFragment(frame, index: Int(index), retransmission: true, into: &rw) else { continue }
            path.retransmitsSent &+= 1
            return finish(chunkBytes: rw.written, into: buf, at: now,
                          payload: .media(stream: frame.stream, frameID: frame.frameID, fragmentIndex: index))
        }

        for queue in [\SendQueues.audio, \SendQueues.video] {
            while let frame = queues[keyPath: queue].first {
                if frame.isComplete { queues[keyPath: queue].removeFirst(); continue }
                let index = frame.nextIndex
                let cost = datagramCost(payload: frame.payloadLength(of: index))
                guard pacer.take(cost) else { return nil }
                var fw = ByteWriter(plaintextScratch)
                guard writeFragment(frame, index: index, retransmission: false, into: &fw) else {
                    frame.nextIndex += 1
                    continue
                }
                frame.nextIndex += 1
                if frame.isComplete {
                    queues[keyPath: queue].removeFirst()
                    updatePacingRate()
                }
                streamStats(frame.stream).fragmentsSent &+= 1
                return finish(chunkBytes: fw.written, into: buf, at: now,
                              payload: .media(stream: frame.stream, frameID: frame.frameID,
                                              fragmentIndex: UInt16(index)))
            }
        }
        return nil
    }

    /// `max(pacingGain × targetBitrate, queuedBytes / spreadTarget)`, capped by
    /// the link-rate ceiling.
    ///
    /// The queued total, not the newest frame, is what has to leave within a
    /// frame interval: a 500 KB IDR still gets spread rather than dumped, and a
    /// small frame queued behind it does not drop the rate back.
    func updatePacingRate() {
        pacer.setRate(Pacer.rate(targetBitrate: bitrate.target, frameBytes: queues.queuedBytes,
                                 frameInterval: config.frameInterval, config: engine))
    }

    func datagramCost(payload: Int) -> Int {
        Wire.headerSize + Wire.chunkHeaderSize + Wire.fragmentHeaderSize + Wire.fecTLVSize
            + payload + Wire.tagSize
    }

    private func writeFragment(_ frame: SendFrame, index: Int, retransmission: Bool,
                               into w: inout ByteWriter) -> Bool {
        do {
            let site = try w.beginChunk(.mediaFragment)
            try frame.fragmentHeader(index, retransmission: retransmission).encode(into: &w)
            try frame.copyFragment(index, into: &w)
            w.endChunk(site)
            return true
        } catch {
            return false
        }
    }

    /// Seals the chunk area and writes the finished datagram into `buf`.
    private func finish(chunkBytes: Int, into buf: UnsafeMutableRawBufferPointer, at now: Instant,
                        payload: SentPacket.Payload) -> Outgoing? {
        let seq = nextTransportSeq
        let truncated = UInt32(truncatingIfNeeded: seq)
        let header = PacketHeader(sessionID: sessionID, transportSeq: truncated,
                                  sendTimeMicros: now.microsTruncated)
        var hw = ByteWriter(buf)
        guard (try? header.encode(into: &hw)) != nil else { return nil }
        guard let sealedLength = protection.seal(
            plaintext: UnsafeRawBufferPointer(rebasing: plaintextScratch[..<chunkBytes]),
            header: UnsafeRawBufferPointer(rebasing: buf[..<Wire.headerSize]),
            packetNumber: seq,
            into: UnsafeMutableRawBufferPointer(rebasing: buf[Wire.headerSize...]))
        else { return nil }

        nextTransportSeq &+= 1
        let total = Wire.headerSize + sealedLength
        sentLog.record(seq: truncated, at: now, bytes: total, payload: payload)
        path.packetsSent &+= 1
        path.bytesSent &+= UInt64(total)
        lastSent = now
        return Outgoing(length: total, destination: peer)
    }

    // MARK: - Control chunks

    /// Packs every due control chunk into one datagram. Returns false when there
    /// is nothing to send.
    private func writeControlChunks(into w: inout ByteWriter, at now: Instant, space: Int) -> Bool {
        var wrote = false

        if let code = pendingClose {
            pendingClose = nil
            closeSentCode = code
            if let site = try? w.beginChunk(.close), (try? w.put(code.rawValue)) != nil {
                w.endChunk(site)
                wrote = true
                log.record(.close, at: now, detail: UInt32(code.rawValue))
            }
        }

        if pendingResume, space - w.written > 8 {
            // Repeated with backoff until STATE arrives.
            if let site = try? w.beginChunk(.resume), (try? w.put(resumeFlags.rawValue)) != nil {
                w.endChunk(site)
                wrote = true
                pendingResume = false
            }
        }

        if pendingPark, space - w.written > 6 {
            pendingPark = false
            if let site = try? w.beginChunk(.park) {
                w.endChunk(site)
                wrote = true
                log.record(.park, at: now)
            }
        }

        while let (id, arrivedAt) = pendingPongs.first, space - w.written > 14 {
            pendingPongs.removeFirst()
            let hold = UInt32(truncatingIfNeeded: (now - arrivedAt).micros)
            if let site = try? w.beginChunk(.pong),
               (try? Pong(id: id, holdMicros: hold).encode(into: &w)) != nil {
                w.endChunk(site)
                wrote = true
            }
        }

        while let id = pendingPings.first, space - w.written > 10 {
            pendingPings.removeFirst()
            if let site = try? w.beginChunk(.ping), (try? w.put(id)) != nil {
                w.endChunk(site)
                wrote = true
            }
        }

        while let request = pendingRefresh.first, space - w.written > 22 {
            pendingRefresh.removeFirst()
            if let site = try? w.beginChunk(.refreshRequest), (try? request.encode(into: &w)) != nil {
                w.endChunk(site)
                wrote = true
                streamStats(request.stream).refreshRequestsSent &+= 1
                log.record(.refreshRequested, at: now, detail: request.lostFrame)
            }
        }

        for (stream, entries) in pendingNacks where !entries.isEmpty {
            let room = space - w.written - Wire.chunkHeaderSize - 1
            guard room >= NackEntry.entrySize else { continue }
            let fit = min(entries.count, room / NackEntry.entrySize)
            if let site = try? w.beginChunk(.nack),
               (try? Nack.encode(into: &w, stream: stream, entries: entries.prefix(fit))) != nil {
                w.endChunk(site)
                wrote = true
                path.nacksSent &+= UInt64(fit)
                pendingNacks[stream] = Array(entries.dropFirst(fit))
            }
        }
        pendingNacks = pendingNacks.filter { !$0.value.isEmpty }

        if !pendingFrameAcks.isEmpty {
            let room = space - w.written - Wire.chunkHeaderSize
            let fit = min(pendingFrameAcks.count, max(0, room) / FrameAckEntry.entrySize)
            if fit > 0, let site = try? w.beginChunk(.frameAck),
               (try? FrameAck.encode(into: &w, entries: pendingFrameAcks.prefix(fit))) != nil {
                w.endChunk(site)
                wrote = true
                pendingFrameAcks.removeFirst(fit)
            }
        }

        if pendingFeedback {
            let room = space - w.written - Wire.chunkHeaderSize
            arrivals.catchUp()
            let count = arrivals.unreportedCount(limit: FeedbackHeader.capacity(bytesAvailable: max(room, 0)))
            if count > 0 {
                let mark = w.written
                let base = arrivals.nextToReport
                if let site = try? w.beginChunk(.feedback),
                   (try? Feedback.encode(into: &w, baseSeq: base, count: count,
                                         arrival: { [self] seq in arrivals.arrivalMicros(seq) })) != nil {
                    w.endChunk(site)
                    wrote = true
                    arrivals.advance(by: count)
                    if !arrivals.hasUnreported { pendingFeedback = false }
                } else {
                    w.rewind(to: mark)
                    pendingFeedback = false
                }
            } else {
                pendingFeedback = false
            }
        }

        // One reliable segment per datagram keeps the accounting simple; stream 0
        // goes first, because control is never allowed to queue behind data.
        for stream in reliable.keys.sorted() {
            guard let segment = reliable[stream]?.nextSendable(at: now, rto: path.rtt.rto) else { continue }
            let room = space - w.written - Wire.chunkHeaderSize - 9
            guard segment.bytes.count <= room else { continue }
            if let site = try? w.beginChunk(.reliable),
               (try? ReliableHeader(stream: stream, msgSeq: segment.msgSeq,
                                    segIndex: segment.index, segCount: segment.count).encode(into: &w)) != nil,
               (try? w.put(segment.bytes)) != nil {
                w.endChunk(site)
                wrote = true
                reliable[stream]?.markSent(msgSeq: segment.msgSeq, index: segment.index, at: now)
                pendingReliableSeq = (stream, segment.msgSeq, segment.index)
                break
            }
        }

        while let (stream, bytes) = pendingDatagrams.first,
              bytes.count + Wire.chunkHeaderSize + 1 <= space - w.written {
            pendingDatagrams.removeFirst()
            if let site = try? w.beginChunk(.datagram), (try? w.put(stream)) != nil,
               (try? w.put(bytes)) != nil {
                w.endChunk(site)
                wrote = true
            }
        }

        return wrote
    }
}
