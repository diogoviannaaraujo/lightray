import LightrayCore
import LightrayCrypto

// The receive path: authenticate, check replay, then dispatch chunks. Unknown
// chunk types are skipped, so a later version can add chunks without a bump.

extension Connection {

    /// Feeds one datagram in. Anything that fails authentication, the version
    /// check or the replay window is dropped silently and counted.
    public func handle(datagram: UnsafeRawBufferPointer, from source: PeerAddress, at now: Instant) {
        guard state != .closed, datagram.count >= 1 else { return }

        if PacketHeader.isHandshake(firstByte: datagram[0]) {
            handleHandshakePacket(datagram, from: source, at: now)
            return
        }
        guard datagram.count >= Wire.minProtectedSize else {
            path.datagramsDropped &+= 1
            return
        }

        let header: PacketHeader
        do {
            let span = RawSpan(_unsafeBytes: datagram)
            var r = ByteReader(span)
            header = try PacketHeader.decode(&r)
        } catch {
            path.datagramsDropped &+= 1
            return
        }
        guard header.sessionID == sessionID else {
            path.datagramsDropped &+= 1
            return
        }

        // Reconstruct the full packet number before opening: the nonce needs all
        // 64 bits even though only 32 travel.
        let priorHighest = replay.seen ? replay.highest : 0
        let packetNumber = reconstructSequence(truncated: header.transportSeq,
                                               expected: replay.seen ? priorHighest &+ 1 : 0)

        guard let plainLength = protection.open(
            sealed: UnsafeRawBufferPointer(rebasing: datagram[Wire.headerSize...]),
            header: UnsafeRawBufferPointer(rebasing: datagram[..<Wire.headerSize]),
            packetNumber: packetNumber,
            into: receiveScratch)
        else {
            path.datagramsDropped &+= 1
            return
        }

        let strictlyNewest = !replay.seen || packetNumber > priorHighest
        guard replay.accept(packetNumber) else {
            path.replayDropped &+= 1
            return
        }
        if !strictlyNewest { path.reordered &+= 1 }

        // Rebind only on a packet that authenticated, passed the replay window
        // and is newer than anything seen. An old packet from a new address, the
        // shape an off-path attacker can most easily produce, moves nothing.
        if source != peer {
            if strictlyNewest {
                peer = source
                path.rebinds &+= 1
                log.record(.rebind, at: now)
                push(.rebound(source))
                // A silent rebind when the session was live: NAT rebinding or
                // Wi-Fi roaming needs no IDR.
                if state == .parked || state == .pipelineIdle { resumeFromParked(at: now) }
            } else {
                path.datagramsDropped &+= 1
                return
            }
        }

        path.packetsReceived &+= 1
        path.bytesReceived &+= UInt64(datagram.count)
        lastReceived = now
        let arrivalMicros = now.microsTruncated
        arrivals.record(seq: header.transportSeq, micros: arrivalMicros)
        path.recordTransit(sendMicros: header.sendTimeMicros, arrivalMicros: arrivalMicros,
                           previous: &lastTransitMicros)
        if !pendingFeedback, arrivals.hasUnreported { pendingFeedback = now >= nextFeedbackAt }

        // A host that receives anything for a parked session resumes it.
        if role == .host, state == .parked || state == .pipelineIdle {
            resumeFromParked(at: now)
        }

        dispatchChunks(length: plainLength, header: header, at: now)
    }

    private func dispatchChunks(length: Int, header: PacketHeader, at now: Instant) {
        let span = RawSpan(_unsafeBytes: UnsafeRawBufferPointer(rebasing: receiveScratch[..<length]))
        var r = ByteReader(span)
        while true {
            guard let chunk = try? r.nextChunk() else { return }
            guard let type = chunk.knownType else { continue }   // must-ignore
            var body = ByteReader(chunk.body)
            switch type {
            case .mediaFragment:
                guard let fragment = try? body.fragment() else { continue }
                handleFragment(fragment.header, payload: fragment.payload, at: now)
            case .reliable:
                guard let segment = try? body.reliableSegment() else { continue }
                handleReliable(segment.header, payload: segment.payload, at: now)
            case .datagram:
                guard let stream = try? body.u8() else { continue }
                let rest = body.rest()
                var bytes = [UInt8](repeating: 0, count: rest.byteCount)
                if rest.byteCount > 0 {
                    bytes.withUnsafeMutableBytes { dst in rest.withUnsafeBytes { dst.copyMemory(from: $0) } }
                }
                push(.datagramReceived(stream: stream, bytes: bytes))
            case .feedback:
                handleFeedback(&body, sendTimeMicros: header.sendTimeMicros, at: now)
            case .nack:
                handleNack(&body, at: now)
            case .frameAck:
                try? FrameAck.decode(&body) { [self] entry in
                    if entry.status == .decoded { ltrAcks[entry.stream]?.record(entry.frameID) }
                }
            case .refreshRequest:
                guard let request = try? RefreshRequest.decode(&body) else { continue }
                handleRefreshRequest(request, at: now)
            case .ping:
                guard let id = try? body.u32() else { continue }
                pendingPongs.append((id, now))
            case .pong:
                guard let pong = try? Pong.decode(&body) else { continue }
                if let sentAt = pingSentAt.removeValue(forKey: pong.id) {
                    let round = now - sentAt
                    let hold = Interval.microseconds(UInt64(pong.holdMicros))
                    path.rtt.record(round > hold ? round - hold : round)
                }
            case .park:
                if role == .host { park(at: now) }
            case .resume:
                let flags = ResumeFlags(rawValue: (try? body.u8()) ?? 0)
                if role == .host { handleResumeRequest(flags, at: now) }
            case .close:
                let code = CloseCode(rawValue: (try? body.u16()) ?? 0) ?? .normal
                state = .closed
                log.record(.close, at: now, detail: UInt32(code.rawValue))
                push(.closed(code))
                return
            }
        }
    }

    // MARK: - Media

    private func handleFragment(_ header: FragmentHeader, payload: RawSpan, at now: Instant) {
        guard header.fecScheme == 0 else { return }   // v0 implements NONE only
        guard let reassembler = reassemblers[header.stream] else { return }
        let deadline = Interval(nanos: config.frameInterval.nanos * engine.frameDeadlineIntervals)
        switch reassembler.accept(header, payload: payload, at: now, deadline: deadline) {
        case .complete(let slot):
            deliverCompleted(reassembler, slot: slot, at: now)
        case .duplicate, .progress, .rejected:
            break
        }
    }

    private func deliverCompleted(_ reassembler: Reassembler, slot: Int, at now: Instant) {
        guard let done = reassembler.takeCompleted(slot) else { return }
        let stream = reassembler.stream
        let deadline = now + Interval(nanos: config.frameInterval.nanos * engine.frameDeadlineIntervals)
        var queue = held[stream] ?? []
        queue.append(HeldFrame(frameID: done.frameID, buffer: done.buffer, byteCount: done.byteCount,
                               firstArrival: done.firstArrival, deadline: deadline,
                               keyframe: done.keyframe))
        queue.sort { serialGreater($1.frameID, $0.frameID) }
        held[stream] = queue
        drainHeld(stream: stream, at: now, force: false)
    }

    /// Delivers held frames in `frame_id` order while the head is decodable.
    ///
    /// `force` lets a deadline sweep clear a head that is waiting on a
    /// predecessor that is never going to arrive.
    func drainHeld(stream: UInt8, at now: Instant, force: Bool) {
        guard let reassembler = reassemblers[stream] else { return }
        while var queue = held[stream], !queue.isEmpty {
            let head = queue[0]
            let bytes = UnsafeRawBufferPointer(rebasing: head.buffer[..<head.byteCount])
            guard let layout = try? FrameHeader.parse(bytes) else {
                reassembler.recycle(head.buffer)
                queue.removeFirst()
                held[stream] = queue
                continue
            }
            guard var tracker = decodability[stream] else {
                // A realtime stream has no gate: deliver it and move on.
                queue.removeFirst()
                held[stream] = queue
                deliverHeld(head, stream: stream, layout: layout, at: now, gated: false)
                continue
            }
            let verdict = tracker.verdict(for: layout.header, frameID: head.frameID)
            if verdict == .undecodable {
                // Wait: an earlier frame still in reassembly may make this one
                // decodable. Past its deadline, it never will.
                let expired = force || now >= head.deadline
                if !expired, waitingOnEarlierFrame(stream: stream, before: head.frameID,
                                                   tracker: tracker) {
                    return
                }
                tracker.recordGap()
                decodability[stream] = tracker
                reassembler.recycle(head.buffer)
                queue.removeFirst()
                held[stream] = queue
                streamStats(stream).framesGatedUndecodable &+= 1
                push(.frameUndecodable(stream: stream, frameID: head.frameID))
                requestRefresh(stream: stream, reason: .loss, lostFrame: head.frameID,
                               lastGood: tracker.lastDeliveredFrameID, at: now)
                continue
            }

            tracker.recordDelivered(frameID: head.frameID, isKeyframe: layout.header.isKeyframe)
            decodability[stream] = tracker
            queue.removeFirst()
            held[stream] = queue
            deliverHeld(head, stream: stream, layout: layout, at: now, gated: true)
        }
    }

    /// Hands one frame to the app and records what it cost.
    private func deliverHeld(_ head: HeldFrame, stream: UInt8, layout: FrameLayout,
                             at now: Instant, gated: Bool) {
        let latency = now - head.firstArrival
        let reclaimer = self.reclaimer
        let frame = ReceivedFrame(stream: stream, frameID: head.frameID, header: layout.header,
                                  arrivedAt: now, completionLatency: latency,
                                  buffer: head.buffer,
                                  codecConfigRange: layout.codecConfig,
                                  payloadRange: layout.payload,
                                  returnBuffer: { buffer in reclaimer.give(buffer) })
        var stats = self.stats(for: stream)
        stats.framesDelivered &+= 1
        stats.bytesDelivered &+= UInt64(head.byteCount)
        stats.completionLatency.record(latency.micros)
        if layout.header.isKeyframe {
            stats.keyframesDelivered &+= 1
            log.record(.keyframeDelivered, at: now, detail: head.frameID)
        }
        setStats(stats, for: stream)

        // At most one LTR ack per interval, once the app reports it decoded.
        if gated, layout.header.ltrMarked, capabilities.contains(.ltr) {
            let last = lastLTRAckAt[stream] ?? .zero
            if pendingLTRAck[stream] == nil, now - last >= engine.ltrAckInterval {
                pendingLTRAck[stream] = head.frameID
            }
        }
        if let started = resumeRequestedAt, layout.header.isKeyframe {
            reconnect.resumeLatency.record((now - started).micros)
            resumeRequestedAt = nil
        }
        push(.frameReceived(frame))
    }

    /// True while a frame older than `frameID` could still turn up.
    private func waitingOnEarlierFrame(stream: UInt8, before frameID: UInt32,
                                       tracker: DecodabilityTracker) -> Bool {
        guard let reassembler = reassemblers[stream] else { return false }
        return reassembler.hasFrameOlderThan(frameID)
    }

    /// Returns every held frame's buffer. Part of what a park releases.
    func flushHeld() {
        for (stream, queue) in held {
            for frame in queue { reassemblers[stream]?.recycle(frame.buffer) }
        }
        held.removeAll(keepingCapacity: true)
    }

    /// The app reports a frame decoded, which is what lets this receiver offer it
    /// as an LTR reference: it only ever acks frames it decoded.
    public func reportDecoded(stream: UInt8, frameID: UInt32, at now: Instant) {
        guard pendingLTRAck[stream] == frameID else { return }
        pendingLTRAck[stream] = nil
        lastLTRAckAt[stream] = now
        pendingFrameAcks.append(FrameAckEntry(stream: stream, frameID: frameID, status: .decoded))
        // The set this receiver will accept an LTR reference against is exactly
        // the set it acked, so `ltrAny` can never be accepted for a frame the
        // sender could not have known about.
        decodability[stream]?.recordDecodedLTR(frameID: frameID)
        streamStats(stream).ltrAcksSent &+= 1
    }

    /// The app reports its decoder unusable, so nothing predicted may be
    /// delivered until a recovery frame arrives.
    public func reportDecoderLost(stream: UInt8, at now: Instant) {
        decodability[stream]?.reset()
        requestRefresh(stream: stream, reason: .decoderReset, lostFrame: 0, lastGood: 0, at: now)
    }

    func requestRefresh(stream: UInt8, reason: RefreshReason, lostFrame: UInt32,
                        lastGood: UInt32, at now: Instant) {
        // One outstanding request per stream; it is repeated until a recovery
        // frame arrives, not stacked.
        guard !pendingRefresh.contains(where: { $0.stream == stream }) else { return }
        let preference: RefreshPreference =
            (capabilities.contains(.ltr) && !engine.forceIDROnly) ? .ltr : .idr
        let request = RefreshRequest(stream: stream, reason: reason, preferred: preference,
                                     lastGoodFrame: lastGood, lostFrame: lostFrame,
                                     reqID: nextRefreshReqID)
        nextRefreshReqID &+= 1
        pendingRefresh.append(request)
    }

    private func handleRefreshRequest(_ request: RefreshRequest, at now: Instant) {
        streamStats(request.stream).refreshRequestsReceived &+= 1
        log.record(.refreshSent, at: now, detail: request.lostFrame)
        // Offer the encoder the whole retained acked set and let it choose; it
        // does not report which one it used, so the refresh frame is marked
        // ltrAny and the receiver accepts it unconditionally.
        if request.preferred == .ltr, capabilities.contains(.ltr), !engine.forceIDROnly,
           let set = ltrAcks[request.stream], !set.isEmpty {
            push(.refreshRequired(stream: request.stream, preference: .ltr, ltrCandidates: set.candidates))
        } else {
            push(.refreshRequired(stream: request.stream, preference: .idr, ltrCandidates: []))
        }
    }

    // MARK: - Feedback and NACK

    private func handleFeedback(_ r: inout ByteReader, sendTimeMicros: UInt32, at now: Instant) {
        var newestReceived: (seq: UInt32, arrival: UInt32)?
        var ackedReliable: [(UInt8, UInt32, UInt16)] = []
        guard (try? Feedback.decode(&r, onPacket: { [self] seq, arrival in
            if let arrival {
                if newestReceived == nil || serialGreater(seq, newestReceived!.seq) {
                    newestReceived = (seq, arrival)
                }
                if let entry = sentLog.markAcked(seq) {
                    bitrate.recordDelivered()
                    if case .reliable(let stream, let msgSeq, let segIndex) = entry.payload {
                        ackedReliable.append((stream, msgSeq, segIndex))
                    }
                }
            } else if sentLog.markLost(seq) != nil {
                bitrate.recordLost()
                path.gaps &+= 1
            }
        })) != nil else { return }

        for (stream, msgSeq, segIndex) in ackedReliable {
            reliable[stream]?.markAcked(msgSeq: msgSeq, index: segIndex)
        }

        // RTT from the hold time: both terms come from the peer's clock, so the
        // two clocks never have to agree. No PING needed on an active link.
        if let newest = newestReceived, let sent = sentLog.lookup(newest.seq) {
            let hold = Int64(Int32(bitPattern: sendTimeMicros &- newest.arrival))
            let round = now - sent.sentAt
            if hold >= 0, round.micros > UInt64(hold) {
                path.rtt.record(Interval.microseconds(round.micros - UInt64(hold)))
            } else {
                path.rtt.record(round)
            }
        }
    }

    private func handleNack(_ r: inout ByteReader, at now: Instant) {
        var entries: [NackEntry] = []
        guard let stream = try? Nack.decode(&r, onEntry: { entries.append($0) }) else { return }
        path.nacksReceived &+= UInt64(entries.count)
        for entry in entries {
            guard let frame = retransmits.frame(stream, entry.frameID) else {
                // Already evicted: the only honest answer is a refresh.
                push(.refreshRequired(stream: stream,
                                      preference: (capabilities.contains(.ltr) && !engine.forceIDROnly)
                                          ? .ltr : .idr,
                                      ltrCandidates: ltrAcks[stream]?.candidates ?? []))
                continue
            }
            let range: Range<Int> = entry.isWholeFrame
                ? 0..<frame.fragmentCount
                : Int(entry.first)..<min(Int(entry.first) + Int(entry.count), frame.fragmentCount)
            for i in range {
                guard retransmits.shouldRetransmit(frameID: entry.frameID, index: UInt16(i),
                                                   now: now, srtt: path.rtt.smoothed)
                else { continue }
                queues.retransmissions.push((frame, UInt16(i)))
            }
        }
    }

    // MARK: - Reliable control channel

    private func handleReliable(_ header: ReliableHeader, payload: RawSpan, at now: Instant) {
        if reliable[header.stream] == nil {
            reliable[header.stream] = ReliableChannel(stream: header.stream)
        }
        guard let messages = reliable[header.stream]?.receive(header, payload: payload) else { return }
        for message in messages {
            guard header.stream == 0 else {
                push(.reliableMessage(stream: header.stream, bytes: message))
                continue
            }
            message.withUnsafeBytes { raw in
                let span = RawSpan(_unsafeBytes: raw)
                var r = ByteReader(span)
                guard let body = try? ControlBody.decode(&r) else { return }
                handleControl(body, at: now)
            }
        }
    }

    private func handleControl(_ body: ControlBody, at now: Instant) {
        switch body.message {
        case .reconfigure:
            let rejected = body.apply(to: &config)
            resizeScratchIfNeeded()
            if let bps = body.bitrate, rejected == 0 { bitrate.setManualTarget(bps, floor: body.bitrateFloor) }
            pacer.setRate(Pacer.rate(targetBitrate: bitrate.target, frameBytes: 0,
                                     frameInterval: config.frameInterval, config: engine))
            var result = ControlBody.state(config: config, flags: bitrate.backstopEngaged ? [.backstop] : [])
            result.message = .reconfigureResult
            result.reqID = body.reqID
            result.rejectedMask = rejected
            sendReliable(encodeControl(result))
            log.record(.reconfigure, at: now, detail: UInt32(config.generation))
            push(.configurationChanged(config))
        case .reconfigureResult:
            var applied = config
            _ = body.apply(to: &applied)
            applied.generation = body.generation ?? applied.generation
            config = applied
            resizeScratchIfNeeded()
            push(.reconfigureResult(reqID: body.reqID, config: config, rejectedMask: body.rejectedMask))
        case .state:
            var applied = config
            _ = body.apply(to: &applied)
            applied.generation = body.generation ?? applied.generation
            config = applied
            resizeScratchIfNeeded()
            if body.stateFlags.contains(.resume), awaitingResumeState {
                completeClientResume(at: now)
            }
            peerBackstopEngaged = body.stateFlags.contains(.backstop)
            if peerBackstopEngaged { log.record(.backstop, at: now) }
            push(.configurationChanged(config))
        }
    }

    func resizeScratchIfNeeded() {
        let needed = Int(config.maxDatagramSize) + 64
        if plaintextScratch.count < needed {
            plaintextScratch.deallocate()
            plaintextScratch = .allocate(byteCount: needed, alignment: 64)
        }
        if receiveScratch.count < needed {
            receiveScratch.deallocate()
            receiveScratch = .allocate(byteCount: needed, alignment: 64)
        }
    }

    // MARK: - Handshake packets on an established connection

    private func handleHandshakePacket(_ datagram: UnsafeRawBufferPointer, from source: PeerAddress,
                                       at now: Instant) {
        guard datagram[0] == HandshakeType.sessionUnknown.rawValue,
              datagram.count >= SessionUnknown.size, role == .client
        else { return }
        let message: SessionUnknown
        do {
            let span = RawSpan(_unsafeBytes: datagram)
            var r = ByteReader(span)
            message = try SessionUnknown.decode(&r)
        } catch { return }
        guard message.sessionID == sessionID else { return }
        // The token is the same value the RESPONSE handed over, so a client can
        // tell a real host from an off-path forgery without any host secret.
        guard message.token == expectedResetToken else {
            path.datagramsDropped &+= 1
            return
        }
        reconnect.sessionUnknownReceived &+= 1
        log.record(.sessionLost, at: now, detail: sessionID)
        state = .closed
        push(.sessionLost)
    }
}
