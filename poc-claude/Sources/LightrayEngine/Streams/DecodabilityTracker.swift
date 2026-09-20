import LightrayCore

/// Keeps undecodable frames away from the decoder.
///
/// Phase 0 measured why this is not optional: with two frames lost and no
/// refresh, the H.264 decoder returns noErr and outputs corrupted frames. HEVC
/// reports an error instead, but neither should be handed a frame whose
/// references are gone.
struct DecodabilityTracker {
    /// True while the decoder has every reference it needs.
    private(set) var gateOpen = false
    private(set) var lastDeliveredFrameID: UInt32 = 0
    private var hasDelivered = false
    /// Frames this receiver acked as decoded, which the sender may reference.
    private(set) var ackedLTR: [UInt32] = []
    /// IDR-only recovery, for the test that exercises the fallback.
    var forceIDROnly: Bool
    let maxAckedLTR: Int

    init(forceIDROnly: Bool, maxAckedLTR: Int) {
        self.forceIDROnly = forceIDROnly
        self.maxAckedLTR = maxAckedLTR
    }

    enum Verdict: Equatable {
        case deliver
        /// Hold it back and ask for a refresh.
        case undecodable
    }

    /// Whether this frame's references are all available.
    ///
    /// The gate is per reference kind, not global: a gap stops `.previous`
    /// frames, but that is exactly the situation a recovery frame exists to fix,
    /// so an IDR or a frame referencing the acked set must still get through.
    func verdict(for header: FrameHeader, frameID: UInt32) -> Verdict {
        // An IDR needs nothing and reopens everything.
        if header.frameType == .idr { return .deliver }
        switch header.refKind {
        case .none:
            return .deliver
        case .previous:
            // Needs the frame immediately before it. Ids are assigned only to
            // frames that produced bytes, so a hole here is a real gap and not a
            // capture the encoder skipped.
            return gateOpen && hasDelivered && frameID == lastDeliveredFrameID &+ 1
                ? .deliver : .undecodable
        case .ltr:
            guard !forceIDROnly, let ref = header.refFrameID else { return .undecodable }
            return ackedLTR.contains(ref) || (hasDelivered && ref == lastDeliveredFrameID)
                ? .deliver : .undecodable
        case .ltrAny:
            // Accepted unconditionally against a non-empty acked set: the encoder
            // chose from the frames this receiver said it had decoded, and it only
            // ever says that about frames it decoded.
            return (!forceIDROnly && !ackedLTR.isEmpty) ? .deliver : .undecodable
        }
    }

    mutating func recordDelivered(frameID: UInt32, isKeyframe: Bool) {
        lastDeliveredFrameID = frameID
        hasDelivered = true
        gateOpen = true
    }

    /// A gap closes the gate: nothing predicted may reach the decoder until an
    /// IDR, or a frame referencing an acked LTR, arrives.
    mutating func recordGap() { gateOpen = false }

    /// Records that the app decoded a frame, so it may be offered as a reference.
    mutating func recordDecodedLTR(frameID: UInt32) {
        guard !ackedLTR.contains(frameID) else { return }
        ackedLTR.append(frameID)
        if ackedLTR.count > maxAckedLTR { ackedLTR.removeFirst(ackedLTR.count - maxAckedLTR) }
    }

    /// A resume discards everything: the decoder is rebuilt from the recovery IDR.
    mutating func reset() {
        gateOpen = false
        hasDelivered = false
        lastDeliveredFrameID = 0
        ackedLTR.removeAll(keepingCapacity: true)
    }
}

/// The sender's view of what the receiver has acked as decoded, which is what it
/// can offer an encoder for an LTR refresh.
struct LTRAckSet {
    private(set) var acked: [UInt32] = []
    let limit: Int

    init(limit: Int) { self.limit = limit }

    mutating func record(_ frameID: UInt32) {
        guard !acked.contains(frameID) else { return }
        acked.append(frameID)
        if acked.count > limit { acked.removeFirst(acked.count - limit) }
    }

    var candidates: [UInt32] { acked }
    var isEmpty: Bool { acked.isEmpty }
    mutating func reset() { acked.removeAll(keepingCapacity: true) }
}
