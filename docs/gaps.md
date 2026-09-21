# What version 0 does not settle

Two kinds of thing are listed here: features deliberately deferred with a seam reserved
for them, and questions this specification genuinely does not answer. The second kind
matters more — each one is a place where two conforming implementations can still fail
to work together, and anyone building against this document should read them before
starting.

## Open questions

### Input payload encoding

**Status: unspecified. Blocks independent interoperability.**

Version 0 carries input as opaque bytes on a `RELIABLE` stream, in order and without
loss. What those bytes mean — how a key press, a pointer motion, a controller state or a
touch event is encoded — is not defined.

Two implementations written from this document alone will establish a session, exchange
video and audio correctly, and fail to agree on input. A client built against a host it
did not author MUST obtain the input encoding from the host's author.

This is deferred rather than guessed because the encoding is bound to what the host does
with the events — which platform's input model, which controller abstraction, which
coordinate space and scaling rules — and none of that is transport. A version 1 that
specifies it should cover at minimum: keyboard scancodes and their keymap basis, pointer
absolute and relative motion with a defined coordinate space, button and wheel events,
controller state including analogue ranges and dead zones, touch, and a rule for
coalescing high-rate motion.

### Presentation timing

**Status: partially specified.**

`capture_time_us` on every frame is drawn from one monotonic clock on the sending
machine, so audio and video are directly comparable, and [audio.md](audio.md) requires a
receiver to align them by it.

What is not specified: how deep a receiver's playout buffer should be, how it should
choose a presentation instant, what it should do when audio and video drift apart, and
how it should recover from a buffer that has run dry or grown. These are application
decisions with no single right answer — a latency-sensitive use wants a shallow buffer
and visible glitches, a passive one wants the opposite — and the protocol gives an
implementation everything it needs to make them.

### Path MTU discovery

**Status: partially specified.**

The padded `INIT` proves the path can carry `max_datagram_size` at the moment the session
starts, and [packets.md](packets.md) defines what happens when the size changes by
`RECONFIGURE`. There is no mechanism for discovering mid-session that the path has
stopped carrying the chosen size, and no automatic probe to find a size it will carry.

The symptom of a mid-session MTU drop is loss that retransmission cannot repair, because
retransmissions are the same size. A sender that observes a frame failing repeatedly at
full size SHOULD lower `MAX_DATAGRAM_SIZE` by `RECONFIGURE`, but the detection heuristic
is left to the implementation.

### Statistics reporting

**Status: intentionally local.**

[feedback.md](feedback.md) defines how round-trip time, loss, jitter and queuing delay
are derived, because both ends must derive them the same way for the backstop to behave
consistently. How an implementation exposes them to an application — the interface, the
publication rate, what a "link quality" summary means — is not specified and does not
affect interoperability.

### Multiple concurrent clients

**Status: unspecified.**

The protocol demultiplexes by `session_id`, so a host can hold many sessions at once, and
`maxParkedSessions` bounds the parked set. Nothing says how a host should divide capacity
between several active sessions, or whether it should accept more than one at all. A host
serving one client at a time — the expected case — needs none of this.

An implementation serving several MUST schedule fairly between them; a host that drains
sessions in a fixed order lets one busy client starve the rest.

## Deferred features

Each of these has its seam reserved on the wire, so adding it later is a capability
negotiation rather than a version bump.

### Forward error correction

**Reserved: capability bit 2, the FEC extension TLV on every fragment, the FEC scheme
registry.**

Every media fragment carries `{type 1, length 1, scheme}` and version 0 always writes
scheme `NONE`. A receiver MUST discard a fragment naming a scheme it does not implement,
so a future scheme cannot be mistaken for data.

Version 0 recovers by retransmission, which costs a round trip. FEC trades bandwidth for
latency and is the natural next step for links where a round trip is expensive. The
reserved header bytes in the protected header exist partly so that a scheme can signal
per-packet without a version bump.

### Congestion control

**Reserved: the loss backstop, and the per-packet arrival data in `FEEDBACK`.**

Version 0 sets bitrate manually. `FEEDBACK` already carries everything a controller
needs — per-packet arrival times, from which send and receive rates, one-way delay
variation and queuing delay all follow — and the backstop in
[feedback.md](feedback.md) prevents the worst outcome in the meantime.

What is missing is the controller: a model of the path, a rate signal derived from it,
and a ramp. That is a substantial piece of work with its own failure modes, and shipping
a poor one would be worse than shipping none, because implementations would then have to
interoperate with its mistakes.

### Intra refresh

**Reserved: capability bit 1, frame header flag bit 1.**

Gradual intra refresh spreads the cost of a keyframe across many frames, which removes
the bitrate spike that makes recovery expensive exactly when the link is struggling. A
host MUST NOT accept the capability in version 0, and the frame header flag that would
mark a completed refresh cycle is reserved.

It is deferred because hardware encoders in common use do not expose the control needed
to drive it.

### Rekeying

**Reserved: `key_phase`, bit 6 of the protected header's `flags`.**

Traffic keys last for the life of a session. With a 64-bit packet number and AES-GCM
there is no practical limit to reach in a session of any realistic length, so version 0
does not rekey. The bit is reserved so that a future version can, without a version bump
and without a round trip.

Note that a session adopted on re-handshake already gets fresh keys; see
[reconnect.md](reconnect.md). That is not rekeying — it is a new key schedule for a
session that kept its identity.

### Codec negotiation

**Not reserved. Deliberately absent.**

The codecs are pinned to the wire version: version 0 means HEVC and Opus. Nothing on the
wire carries a codec identifier, and a peer that disagrees fails the version check. A
different codec is a different version, not a negotiation.

### NAT traversal and peer discovery

**Not reserved. Out of scope.**

The application supplies an address. The protocol handles a peer's address *changing* —
see the rebinding rules in [packets.md](packets.md) — but does nothing to establish
reachability in the first place.

### Pairing

**Not reserved. Out of scope.**

The application supplies the pairing identifier and the pre-shared key. How two devices
come to share one is a user-facing flow this protocol does not define. The security
requirements on the key are in [conformance.md](conformance.md).
