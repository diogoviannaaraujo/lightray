/// Wrap-safe comparison for the protocol's 32-bit counters (`transport_seq`,
/// `frame_id`, `msg_seq`): `a` is newer than `b` when the forward distance is
/// less than half the space.
@inlinable
public func serialGreater(_ a: UInt32, _ b: UInt32) -> Bool {
    a != b && (a &- b) < 0x8000_0000
}

@inlinable
public func serialGreaterOrEqual(_ a: UInt32, _ b: UInt32) -> Bool {
    (a &- b) < 0x8000_0000
}

/// Signed forward distance from `b` to `a`, valid while the two are within half
/// the space of each other.
@inlinable
public func serialDistance(_ a: UInt32, _ b: UInt32) -> Int32 {
    Int32(bitPattern: a &- b)
}

/// Rebuilds the full 64-bit counter from the 32 bits on the wire, choosing the
/// candidate closest to `expected` (QUIC's packet-number reconstruction).
@inlinable
public func reconstructSequence(truncated: UInt32, expected: UInt64) -> UInt64 {
    let window: UInt64 = 1 << 32
    let half: UInt64 = 1 << 31
    let base = expected & ~(window - 1)
    let candidate = base | UInt64(truncated)
    if candidate &+ half <= expected, candidate &+ window > candidate { return candidate &+ window }
    if candidate > expected &+ half, candidate >= window { return candidate &- window }
    return candidate
}
