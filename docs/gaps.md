# What version 1 does not settle

Three kinds of thing are listed here: decisions that wait on measurements, questions this
specification does not yet answer, and features deliberately left out with their seams
reserved. The first two shrink as version 1 is written; anyone building against these documents
should read them before starting.

## Waiting on measurements

How Windows hosts behave is being measured on NVIDIA and Intel GPUs, and each row below is a
decision those measurements settle. The document each lands in stays version 0, or unwritten,
until then. The tests are described in the Windows validation brief,
`tools/windows/BRIEF.md` on the `windows-validation` branch.

| Decision | Test | Lands in |
|---|---|---|
| Which recovery methods a Windows host can use, and whether Quick Sync can do more than IDRs | P0-1 | [video.md](video.md) |
| Whether a Windows host can hold a warm park, and what a cold one costs | P0-2 | [session.md](session.md) |
| Whether "no IDR except for resolution, chroma and HDR changes" holds on Windows encoders, and how fast they follow a new target | P1-1 | [control.md](control.md), [rate-control.md](rate-control.md) |
| Whether a resume must budget for a capture restart, and whether hosts need a "video unavailable" notice | P1-2 | [session.md](session.md) |
| The cursor shape format: RGBA alone, or with an invert mask | P1-3 | [input.md](input.md) |
| Whether the keyboard needs the consumer page; what a relative mouse delta means; the wheel's units; whether a host can detect a game capturing the pointer; the rumble fields | P1-4 | [input.md](input.md) |
| Whether `GAME`'s 5 ms audio frames are worth it on Windows | P1-5 | [audio.md](audio.md), [modes.md](modes.md) |
| Whether the pacing requirement is achievable on Windows | P1-6 | [video.md](video.md), [rate-control.md](rate-control.md) |
| HDR metadata inside the bitstream, or in a message of its own | P2-3 | [video.md](video.md) |
| Which chroma formats a Windows host can offer, and whether it can produce a fast-start IDR | P2-4, P2-5 | [modes.md](modes.md), [session.md](session.md) |

The Apple measurements are already in [`notes/`](../notes/README.md).

## Open questions

### The smallest datagram

**Status: open until [modes.md](modes.md) is written.**

A `RESPONSE` must be no larger than the `INIT` that triggered it, and an `INIT` can be as small
as 256 bytes. Once `SETTINGS`, `CAPABILITIES` and `LIFECYCLE` are defined, a `RESPONSE`
carrying all of them has to fit. If it can't, the minimum `max_datagram_size` rises. Settings are
per video stream as well as per session ([displays.md](displays.md)), so a client that proposes
several video streams adds to what the `RESPONSE` reports; the list of the host's displays
travels after the handshake and does not.

### Presentation timing

**Status: partially specified; revisited with [audio.md](audio.md).**

`capture_time_us` on every frame is drawn from one monotonic clock on the sending machine, so
audio and video are directly comparable. How deep a receiver's playout buffer should be, how
it should choose a presentation instant, and what it should do when audio and video drift apart
are application decisions, and version 0 left them to the application.

### Multiple concurrent clients

**Status: unspecified.**

The protocol demultiplexes by `session_id`, so a host can hold many sessions at once. Nothing
says how a host should divide capacity between several active sessions, or whether it should
accept more than one at all. A host serving one client at a time, the expected case, needs none
of this. An implementation serving several MUST schedule fairly between them; a host that
drains sessions in a fixed order lets one busy client starve the rest.

## Deferred features

Where a feature's seam is reserved on the wire, adding it later needs no version bump.

### Rekeying

**Reserved: `key_phase`, bit 6 of the protected header's `flags`.**

Traffic keys last for the life of a session. Noise advises against encrypting more than 2⁵⁶
bytes under one AES-GCM key, which no session approaches, so version 1 does not rekey. The bit
is reserved so that a later version can, without a round trip; Noise's `Rekey()` (section 11.3
of its specification) is the natural mechanism.

A session taken over by a new handshake gets fresh keys ([handshake.md](handshake.md#taking-over-a-session)).
That is not rekeying: it is a new key schedule for a session that kept its identity.

### Path MTU discovery

**Reserved: the `PADDING` chunk.**

The padded `INIT` proves the path can carry `max_datagram_size` when the session starts.
There is no mechanism for discovering mid-session that the path has stopped carrying it, and
no probe to find a size it will carry. A sender that sees a frame failing repeatedly at full
size SHOULD lower the size ([packets.md](packets.md#path-mtu-changes)); how it detects that is
left to the implementation. `PADDING` exists so that a later version can probe with packets
that carry nothing.

### Intra refresh

**Reserved in version 0: a capability bit and a frame header flag. Revisited with
[video.md](video.md).**

Gradual intra refresh spreads the cost of a keyframe across many frames. Version 1's recovery
frames are reference invalidation, a long-term-reference refresh or an IDR, chosen by the
host; whether intra refresh joins them depends on what the encoders expose.

### Camera, touch, pen and motion sensors

**Reserved: stream kind 5 for a camera; input numbers in [input.md](input.md).**

Version 1 carries video and audio from host to client, and input and the microphone from
client to host. The rest get numbers and nothing else.

### Windows, regions and virtual displays

**Not reserved.**

A video stream shows a whole display of the host's ([displays.md](displays.md)). Streaming a
single window or a region of a display, creating a display on the host to match the client's
screen (for a host with none, or an iPad-shaped desktop), and sending audio per display are left
out. Each would be a new kind of thing a stream can show, or a new setting, rather than a change
to the model.

### Codec negotiation

**Not reserved. Deliberately absent.**

The codecs are pinned to the wire version: version 1 means HEVC and Opus. Nothing on the
wire carries a codec identifier, and a peer that disagrees fails the version check. A
different codec is a different version, not a negotiation.

### NAT traversal and peer discovery

**Not reserved. Out of scope.**

The application supplies an address. The protocol follows a peer's address *changing* (see
the rebinding rules in [packets.md](packets.md#rebinding-to-a-new-address)) but does nothing
to establish reachability in the first place. VPNs such as WireGuard and Tailscale solve this
beneath the protocol, and nothing here depends on them.

### Pairing

**Not reserved. Out of scope.**

The application supplies the pairing identifier and the pre-shared key. How two devices
come to share one is a user-facing flow this protocol does not define. The security
requirements on the key are in [conformance.md](conformance.md#requirements).

## Closed since version 0

Version 0 listed these as gaps. Version 1 closes each of them, in documents still being
written:

| Version 0 gap | Version 1 answer |
|---|---|
| Long-term reference lifetime | A reference epoch that counts IDRs and decoder resets, in the frame header and in acknowledgements ([video.md](video.md)) |
| HEVC decoding contract | Low-delay, with no B-frames and no reordering; Main, Main10 and optionally 4:4:4 ([video.md](video.md)) |
| Input payload encoding | Keyboard, pointer, gamepad and cursor messages ([input.md](input.md)) |
| Forward error correction | Per-frame Reed–Solomon, RFC 5510 ([video.md](video.md)) |
| Congestion control | Required delay-based rate control ([rate-control.md](rate-control.md)) |
| Statistics reporting | An optional statistics chunk for client overlays ([feedback.md](feedback.md)) |
