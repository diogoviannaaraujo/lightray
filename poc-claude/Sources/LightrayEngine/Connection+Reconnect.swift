import LightrayCore
import LightrayCrypto

// Reconnect: the priority path. Park releases everything that cannot reach an
// absent peer; a resume flushes both directions and forces an IDR.

extension Connection {

    // MARK: - Host side

    /// Parks the session.
    ///
    /// This immediately releases the retransmit store, pacer queues, reassembly
    /// state and LTR ack state: none of it can reach an absent peer, and a resume
    /// forces an IDR that would discard it anyway. What remains — keys,
    /// packet-number and replay state, the stream table, the config snapshot and
    /// stats — is under 1 KB plus stats, and costs no processing: nothing is sent
    /// to a parked session and no per-session timer runs.
    public func park(at now: Instant) {
        guard role == .host, state == .established else { return }
        state = .parked
        parkedAt = now
        pipelineIdleEmitted = false
        releaseMediaState()
        reconnect.parks &+= 1
        log.record(.park, at: now)
        push(.parked)
    }

    /// Everything a park drops. Keys, replay state and stats are deliberately kept.
    func releaseMediaState() {
        retransmits.removeAll()
        queues.flush()
        flushHeld()
        for (_, r) in reassemblers { r.flush() }
        for id in ltrAcks.keys { ltrAcks[id]?.reset() }
        for id in decodability.keys { decodability[id]?.reset() }
        pendingNacks.removeAll(keepingCapacity: false)
        pendingFrameAcks.removeAll(keepingCapacity: false)
        pendingRefresh.removeAll(keepingCapacity: false)
        pendingDatagrams.removeAll(keepingCapacity: false)
        pendingLTRAck.removeAll(keepingCapacity: false)
        reclaimer.drain(into: pool)
    }

    /// A RESUME arrived for a session the host holds.
    func handleResumeRequest(_ flags: ResumeFlags, at now: Instant) {
        if flags.contains(.decoderLost) {
            for id in decodability.keys { decodability[id]?.reset() }
        }
        if state == .parked || state == .pipelineIdle {
            resumeFromParked(at: now)
        } else {
            // Live session: the client lost its decoder or replaced its socket,
            // so re-send STATE and force a fresh IDR anyway.
            sendState(flags: [.resume])
            emitRefreshForOutboundVideo(at: now)
        }
    }

    /// Brings a parked session back.
    ///
    /// 1. Flush pacer queues, NACK and reassembly state in both directions.
    /// 2. Send STATE reliably.
    /// 3. Emit `.resumed` and a refresh for every outbound video stream, because
    ///    a resume is always an IDR.
    public func resumeFromParked(at now: Instant) {
        guard state == .parked || state == .pipelineIdle else { return }
        state = .established
        parkedAt = nil
        pipelineIdleEmitted = false
        releaseMediaState()
        for id in reliable.keys { reliable[id]?.reset() }
        pacer.reset(at: now)
        bitrate.reset(at: now)
        nextFeedbackAt = now + engine.feedbackInterval
        nextKeepaliveAt = now + engine.keepaliveInterval
        reconnect.resumes &+= 1
        log.record(.resumed, at: now, detail: sessionID)
        sendState(flags: [.resume])
        push(.resumed)
        emitRefreshForOutboundVideo(at: now)
    }

    func emitRefreshForOutboundVideo(at now: Instant) {
        for s in streamTable where isOutbound(s) && (s.kind == .video || s.kind == .camera) {
            // A resume is always an IDR: the receiver's decoder state is gone or
            // unverifiable, and the recovery IDR carries its own CODEC_CONFIG.
            push(.refreshRequired(stream: s.id, preference: .idr, ltrCandidates: []))
            log.record(.refreshSent, at: now, detail: UInt32(s.id))
        }
    }

    /// How long this session has been parked, for the host's sweep.
    public func parkedFor(_ now: Instant) -> Interval? {
        guard let at = parkedAt else { return nil }
        return now - at
    }

    // MARK: - Client side

    /// The app decides what counts as going idle — on macOS, screen lock or the
    /// user stepping away. Best-effort: the host also parks on silence.
    public func requestPark(at now: Instant) {
        guard role == .client else { return }
        pendingPark = true
        queues.flush()
        state = .parked
        parkedAt = now
        reconnect.parks &+= 1
        log.record(.park, at: now)
        push(.parked)
    }

    /// Sends RESUME, repeated with backoff until STATE arrives. The runtime pairs
    /// this with a fresh socket, so the host sees a new source port and rebinds.
    public func requestResume(decoderLost: Bool, at now: Instant) {
        guard role == .client else { return }
        state = .established
        parkedAt = nil
        releaseMediaState()
        for id in reliable.keys { reliable[id]?.reset() }
        if decoderLost { for id in decodability.keys { decodability[id]?.reset() } }
        resumeFlags = decoderLost ? [.decoderLost] : []
        pendingResume = true
        awaitingResumeState = true
        resumeRequestedAt = now
        resumeBackoff = engine.handshakeRetryInitial
        nextResumeRetryAt = now + resumeBackoff
        pacer.reset(at: now)
        log.record(.resumed, at: now, detail: sessionID)
    }

    func completeClientResume(at now: Instant) {
        awaitingResumeState = false
        pendingResume = false
        nextResumeRetryAt = nil
        reconnect.resumes &+= 1
        push(.resumed)
        // The client's own outbound streams need a fresh IDR too (mic, camera).
        emitRefreshForOutboundVideo(at: now)
    }

    public func close(code: CloseCode, at now: Instant) {
        guard state != .closed else { return }
        pendingClose = code
    }

    // MARK: - Timers

    /// The next moment this connection needs attention. The runtime arms one
    /// timer from this; a parked host session has no timer of its own, so a park
    /// really does cost no processing.
    public func nextTimeout(at now: Instant) -> Instant? {
        var earliest: Instant?
        func consider(_ t: Instant?) {
            guard let t else { return }
            if earliest == nil || t < earliest! { earliest = t }
        }
        switch state {
        case .closed:
            return nil
        case .parked, .pipelineIdle:
            // Expiry is one coarse sweep over the parked set, run by the endpoint.
            if role == .client { consider(nextResumeRetryAt) }
            return earliest
        case .idle, .handshaking, .established:
            break
        }
        consider(nextFeedbackAt)
        consider(nextKeepaliveAt)
        consider(nextResumeRetryAt)
        if role == .host { consider(lastReceived + engine.parkAfterSilence) }
        let policy = NackPolicy(reorderWindow: engine.reorderWindow, retryFloor: engine.nackRetryFloor)
        for (_, r) in reassemblers { consider(r.nextNackDeadline(srtt: path.rtt.smoothed, policy: policy)) }
        for (_, channel) in reliable { consider(channel.nextRetransmitDeadline(rto: path.rtt.rto)) }
        // When the pacer is holding media back, wake when the next datagram
        // becomes affordable rather than spinning.
        if queues.queuedFrames > 0 || queues.retransmissions.count > 0 {
            consider(pacer.nextAvailable(bytes: maxDatagramSize, from: now))
        }
        return earliest
    }

    /// Advances every timer. Safe to call more often than needed.
    public func handleTimeout(at now: Instant) {
        guard state != .closed else { return }
        reclaimer.drain(into: pool)

        if let retryAt = nextResumeRetryAt, now >= retryAt, awaitingResumeState {
            // RESUME is repeated with backoff until STATE arrives.
            pendingResume = true
            resumeBackoff = Interval(nanos: min(resumeBackoff.nanos * 2, engine.handshakeRetryMax.nanos))
            nextResumeRetryAt = now + resumeBackoff
        }

        if state == .parked || state == .pipelineIdle {
            if role == .host, let parked = parkedFor(now) {
                if !pipelineIdleEmitted, parked >= engine.pipelineIdleAfter {
                    // The paused pipeline is the only expensive thing a park
                    // holds, which is why this threshold is separate from expiry.
                    pipelineIdleEmitted = true
                    state = .pipelineIdle
                    log.record(.idle, at: now)
                    push(.pipelineIdle)
                }
            }
            return
        }

        if now >= nextFeedbackAt {
            nextFeedbackAt = now + engine.feedbackInterval
            if arrivals.hasUnreported { pendingFeedback = true }
        }

        // The client keeps the link warm so the host does not park a session that
        // is merely quiet; FEEDBACK counts as traffic, so PING only fires on an
        // otherwise silent link.
        if now >= nextKeepaliveAt {
            nextKeepaliveAt = now + engine.keepaliveInterval
            if now - lastSent >= engine.keepaliveInterval, role == .client {
                let id = nextPingID
                nextPingID &+= 1
                pingSentAt[id] = now
                pendingPings.append(id)
                if pingSentAt.count > 64 { pingSentAt.removeAll(keepingCapacity: true) }
            }
        }

        if role == .host, now - lastReceived >= engine.parkAfterSilence {
            park(at: now)
            return
        }

        let policy = NackPolicy(reorderWindow: engine.reorderWindow, retryFloor: engine.nackRetryFloor)
        for (id, r) in reassemblers {
            let entries = r.collectNacks(at: now, srtt: path.rtt.smoothed, policy: policy, limit: 64)
            if !entries.isEmpty { pendingNacks[id, default: []].append(contentsOf: entries) }
            for lost in r.expire(at: now) {
                push(.frameGap(stream: id, frameID: lost))
                // A realtime stream has no gate and no refresh: the gap goes to
                // the app for packet-loss concealment and the stream carries on.
                guard let tracker = decodability[id] else { continue }
                decodability[id]?.recordGap()
                requestRefresh(stream: id, reason: .loss, lostFrame: lost,
                               lastGood: tracker.lastDeliveredFrameID, at: now)
            }
            // A held frame whose predecessor never arrived has to move on.
            if let queue = held[id], let head = queue.first,
               now >= head.deadline || !r.hasFrameOlderThan(head.frameID) {
                drainHeld(stream: id, at: now, force: now >= head.deadline)
            }
        }

        retransmits.trim(now: now)

        if case .clamped(let floor) = bitrate.tick(at: now) {
            // Clamp to the floor, tell the app, and tell the peer so its UI can
            // show it. There is no automatic ramp-up.
            pacer.setRate(Pacer.rate(targetBitrate: floor, frameBytes: 0,
                                     frameInterval: config.frameInterval, config: engine))
            log.record(.backstop, at: now, detail: floor)
            push(.bitrateChanged(floor, reason: .lossBackstop))
            sendState(flags: [.backstop])
        }
    }

    /// Drops frames whose deadline has passed out of the send queues, so a stalled
    /// link does not deliver stale video once it recovers.
    public func dropExpiredOutbound(at now: Instant) {
        queues.video.removeAll { now > $0.deadline && $0.nextIndex == 0 }
    }
}
