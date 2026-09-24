# Protected packets

Every datagram after the handshake is a protected packet: a 16-byte cleartext header,
an encrypted body, and a 16-byte authentication tag. The body is a sequence of chunks.

```
+--------------------------------+
| header (16 bytes, cleartext)   |  authenticated as AAD
+--------------------------------+
| chunk | chunk | chunk | ...    |  encrypted
+--------------------------------+
| tag (16 bytes)                 |
+--------------------------------+
```

The smallest legal protected packet is 32 bytes: a header, an empty body and a tag.

## Header

```
offset  width  field
     0      1  flags
     1      3  reserved
     4      4  session_id
     8      4  transport_seq
    12      4  send_time_us
```

| Field | Meaning |
|---|---|
| `flags` | Bit 7 MUST be 0, marking the short form and distinguishing a protected packet from a handshake packet. Bit 6 is `key_phase`, reserved for rekeying. Bits 5–0 are reserved. |
| `reserved` | Three bytes, written 0 and ignored. |
| `session_id` | The session this packet belongs to, as the host assigned it in the `RESPONSE`. |
| `transport_seq` | The low 32 bits of a per-direction 64-bit packet number. |
| `send_time_us` | The sender's monotonic clock in microseconds, truncated to 32 bits. |

The whole 16 bytes are authenticated as additional data. A receiver MUST discard a packet
whose `session_id` does not match a session it holds, replying with `SESSION_UNKNOWN` only
under the conditions in [handshake.md](handshake.md).

> **Why three reserved bytes and a reserved flag bit.** Something may one day need to be
> signalled on every packet, cheaply and outside the encrypted body so that it can be read
> before decryption. Version 1's rate control reads `send_time_us` and `transport_seq` and its
> forward error correction works per frame, so neither needs the room; it stays reserved so
> that whatever does is not a version bump. It costs four bytes out of 1200.

### Packet numbers

The packet number is a 64-bit counter, one per direction, starting at **0** when the handshake
completes. It increments on **every datagram sent**, including retransmissions and repair
datagrams. Only the low 32 bits travel, as `transport_seq`.

A receiver reconstructs the full number by choosing the candidate congruent to
`transport_seq` modulo 2³² that is nearest to `expected`, taking the larger when two are
equally near. `expected` is one greater than the highest packet number the receiver has so far
authenticated in this direction, and 0 before it has authenticated any. In 64-bit arithmetic,
with every comparison written so that nothing overflows:

```
base      = expected & ~0xFFFFFFFF
candidate = base | transport_seq
if expected >= candidate and expected - candidate >= 2^31 and candidate < 2^64 - 2^32:
    candidate += 2^32
else if candidate > expected and candidate - expected > 2^31 and candidate >= 2^32:
    candidate -= 2^32
```

Some cases, including both sides of the boundary at half the range:

<!-- vector: packets.pn-reconstruction -->
```
expected            transport_seq  packet number
0x0000000000000000  0x00000000     0x0000000000000000
0x0000000000000008  0x00000007     0x0000000000000007
0x00000000fffffffe  0x00000003     0x0000000100000003
0x0000000100000002  0xfffffffd     0x00000000fffffffd
0x0000000100000000  0x80000000     0x0000000180000000
0x0000000100000000  0x80000001     0x0000000080000001
```

A sender MUST NOT use packet number 2⁶⁴ − 1, which Noise reserves, and so MUST close a session
before reaching it. No session comes close: at a million packets a second, it takes over
500 000 years.

> **Why the counter increments on retransmissions.** It makes `transport_seq` a pure
> record of transmission order, which is what lets a receiver report exactly which
> datagrams arrived and in what order without knowing anything about their contents.
> The cost is that the sender must remember what each number carried in order to act on
> that report; see [feedback.md](feedback.md).

### Protection

A packet is sealed with AES-256-GCM under the sending direction's traffic key, which the
handshake derives ([handshake.md](handshake.md#traffic-keys)):

```
key        client-to-host key, or host-to-client key
nonce      0x00000000 ‖ packet_number:u64
AAD        the 16-byte header
plaintext  the chunks
```

The tag is 16 bytes and follows the ciphertext. This is exactly Noise's transport encryption
with the nonce sent alongside each message, as section 11.4 of the Noise specification
describes for messages that can be lost or reordered. The packet number is the nonce, and the
replay window below is the record of accepted nonces that Noise requires such a receiver to
keep.

A sender MUST NOT reuse a packet number under a key. Because the counter increments on every
datagram and never resets within a key, this follows automatically, but an implementation that
rebuilds state on resume MUST ensure the counter restarts only when the keys do.

> **Why there is no IV.** Version 0 mixed a per-direction IV into the nonce. Version 1 uses
> Noise's nonce unchanged, so any Noise library produces the same bytes. The IV's job, making
> the nonce sequence differ between sessions so that an attacker can't work on many of them at
> once, matters far less with 256-bit keys, and every session already has keys of its own.

### Replay window

A receiver MUST maintain a 2048-bit window of packet numbers it has already accepted, and
MUST discard a packet whose number is:

- already recorded in the window, or
- more than 2047 behind the highest number it has authenticated.

The window MUST be updated **only after the packet authenticates**. A receiver MUST NOT
let a packet that fails authentication change any state.

> **Why 2048.** Wide enough that ordinary reordering, including the reordering a
> retransmission naturally causes, never looks like a replay; small enough to be a
> 256-byte bitmap. A window narrower than the number of packets in flight at the highest
> supported bitrate would discard legitimate traffic.

## Addresses

### Rebinding to a new address

A packet arriving from an address other than the session's current peer rebinds that
session **only if all three hold**:

1. it authenticates,
2. it passes the replay window, and
3. its packet number is strictly greater than any previously authenticated for that
   session.

If the session was not parked, the stream simply continues: no keyframe, no message. A rebind
that changes the IP address also starts the validation described next, and resets rate
control. If the session was parked, the rebind is part of resuming; see
[session.md](session.md).

> **Why all three.** The cheapest attack available to someone who can observe traffic but
> not modify it is to capture a valid packet and replay it from elsewhere, hoping to
> redirect the session. Requiring the packet to be strictly newer than everything seen
> defeats that: by the time the copy arrives, the original or a later packet has been
> authenticated. The first two conditions alone would not, because a packet whose original
> was lost never entered the replay window, and a copy of it passes both. An attacker who can
> get a copy in ahead of the original, instead of after it, is what the validation below is
> for.

### Validating a new address

After a rebind that changes the peer's **IP address**, an endpoint MUST NOT send to the new
address more than three times the bytes it has received from it, counting whole UDP payloads,
until the address is validated. An address is validated when a packet from it authenticates and
carries a `FEEDBACK` chunk ([feedback.md](feedback.md)) reporting, as received, a packet that
was sent to that address.

While an address is unvalidated, an endpoint SHOULD spend its allowance on small packets the
peer will report, such as control messages, rather than on media.

Two cases need no validation:

- **A change of port alone.** When only the port changes, as it does after a NAT rebinding or
  when a client resumes from a new socket, the new address is validated from the start.
- **The address a session starts from.** The source address of the `INIT` that created or took
  over a session is validated by the handshake.

A rebind that changes the IP address MUST also reset the sender's rate-control state,
because the path has changed; see [rate-control.md](rate-control.md). A change of port alone
keeps it.

> **Why the cap.** An attacker on the path can race a copy of a genuine packet from a forged
> source address. The copy authenticates and is the newest packet, so it rebinds the session,
> and without a cap the host would aim tens of megabits a second at whoever owns that
> address. The cap bounds what reaches them to three times what the attacker sent. Only the
> real client can report packets that were sent to the address it is really at, so a genuine
> move validates itself within a round trip, and the client's next packet from its real
> address rebinds the session back.

> **Why the exemptions.** Traffic redirected to another port of the same IP address reaches
> the machine that was already receiving the stream, so it cannot be turned on anyone else.
> Exempting it keeps the common case, an iPad resuming from a new socket on the same network,
> at one round trip. The address an `INIT` came from is exempt because requiring validation
> there would add a round trip to every session start, which would make an app that is
> relaunched slower to recover than one that resumes. Starting a session needs the PSK, and a
> replayed `INIT` is answered from the host's cache with a `RESPONSE` smaller than itself
> ([handshake.md](handshake.md#replay-protection)).

## Chunks

The decrypted body is a sequence of chunks, each:

```
type:u8
length:u16          the body length, excluding these three bytes
body[length]
```

Chunks are processed in order. A receiver MUST skip a chunk whose `type` it does not
recognise, using `length`, and continue with the next.

> **Why must-ignore.** It is the only reason a future version can add a chunk type
> without breaking this one. It is worth being strict about: an implementation that
> errors on an unknown type has silently made every future extension a version bump.

### Parsing rules

- A receiver MUST stop parsing when fewer than 3 bytes remain, and MUST ignore those
  trailing bytes.
- A receiver MUST stop parsing if a chunk's `length` exceeds the bytes remaining.
- **A chunk that fails to parse MUST NOT invalidate chunks already processed.** Parsing
  stops at the first chunk header that cannot be read, and everything before it stands.
- A chunk whose header is well formed but whose body is malformed MUST be discarded on
  its own; parsing continues with the next chunk.

> **Why errors are contained rather than fatal.** A datagram is not a transaction. If a
> packet carries a feedback report, a repair request and one malformed chunk, discarding
> all three throws away two useful pieces of information to punish one. Worse, it makes
> the receiver's behaviour depend on chunk ordering, which nothing else in the protocol
> does.

### Packing

A sender MAY place several chunks in one datagram, subject to two rules:

- A `MEDIA_FRAGMENT` MUST be the only chunk in its datagram.
- The whole datagram MUST NOT exceed `max_datagram_size`.

> **Why a media fragment travels alone.** Every fragment except the last of a frame carries
> exactly `stride` payload bytes, and `stride` is what remains of the datagram after the
> fixed overhead ([video.md](video.md)). Anything else sharing the datagram would push the
> fragment over the limit. Control chunks are small and travel together in their own
> datagrams.

### PADDING (`0x00`)

```
body[length]        ignored
```

A chunk that carries nothing. A sender MAY add `PADDING` to any datagram it builds, within the
packing rules, and SHOULD fill its body with zeros. A receiver MUST ignore it.

Zero bytes are always valid padding: three zero bytes are an empty `PADDING` chunk, and fewer
than three at the end of the body are ignored like any other remainder. A sender can therefore
pad a datagram by appending zeros to its chunks.

> **Why padding has a type of its own.** Rate control probes for spare capacity by sending bytes
> that carry nothing ([rate-control.md](rate-control.md)), and a future path-MTU probe will need
> large packets that carry nothing ([gaps.md](gaps.md)). Must-ignore would skip any unassigned
> type, but a type assigned to padding can never collide with a chunk a later version adds.

### CLOSE (`0x34`)

```
code:u16
```

Ends the session immediately. A sender SHOULD send `CLOSE` when it knows the session is
over, because the application asked or the system is about to sleep, but MUST NOT rely on it
arriving.

A receiver MUST treat the session as closed on receipt, and MUST treat an unassigned
code as `NORMAL`. Close codes are in [registries.md](registries.md#close-codes). A receiver
reads the code from the first two bytes of the body and MUST ignore any bytes after them; a
body shorter than two bytes is malformed.

<!-- vector: packets.close -->
```
3400020001
```

| Bytes | Value | Field |
|---|---|---|
| `34` | `0x34` | type, `CLOSE` |
| `0002` | 2 | length |
| `0001` | 1 | code, `APP_REQUEST` |

## Streams

Chunks that carry media or messages name a **stream**. The handshake fixes a session's
streams in a stream table ([handshake.md](handshake.md#stream_table-4)), which gives each
stream an identifier, a kind, a direction and a class. The values are in
[registries.md](registries.md#streams).

- **Stream 0** is never listed. It is always present, bidirectional and of class `RELIABLE`,
  and carries control messages ([control.md](control.md)).
- **The kind** says what a stream carries, such as video, audio, input or the microphone.
- **The direction** says who may send on it: the host, the client, or both.
- **The class** says how loss on the stream is handled, and so which chunks carry its data:

| Class | Loss handling | Data chunks | Defined in |
|---|---|---|---|
| `MEDIA` | Frames are repaired, and a frame whose references are missing is never delivered | `MEDIA_FRAGMENT` | [video.md](video.md) |
| `REALTIME` | Frames are delivered whether or not earlier ones arrived; gaps are reported | audio frames | [audio.md](audio.md) |
| `RELIABLE` | Messages are delivered in order, without loss | `RELIABLE` | [input.md](input.md) |
| `UNRELIABLE` | Messages are delivered if they arrive, and never repaired | `DATAGRAM` | [input.md](input.md) |

A chunk names a stream in one of two roles:

- A **data chunk** carries the stream's own data, and travels in the stream's direction.
- A **feedback chunk** reports on the stream's data or asks for a repair, and travels against
  it: `NACK`, `FRAME_ACK` and `REFRESH_REQUEST` ([feedback.md](feedback.md)).

On a bidirectional stream, both directions are right for both roles. A receiver MUST discard a
chunk, and SHOULD count the event, when the chunk:

- names a stream that is not in the table;
- travels the wrong way for its role, such as a media fragment reaching a client on a
  client-to-host stream; or
- is a data chunk that does not belong to the stream's class, such as a `RELIABLE` chunk on a
  `MEDIA` stream.

Discarding one chunk leaves the rest of the datagram unaffected.

> **Why the class is separate from the kind.** The distinction that matters to a receiver is
> not what the bytes represent but how a loss must be handled. Audio and video are both
> media, but withholding an audio frame because an earlier one is missing produces a gap the
> listener hears, where withholding a video frame prevents visible corruption. Deriving
> behaviour from the kind forces that difference to be hard-coded; carrying the class lets the
> stream table say it.

## A complete protected datagram

Host to client, packet number 7, sent when the host's clock read 2 500 000 µs, carrying one
`CLOSE` with code `GOING_AWAY`, and sealed with the host-to-client key derived in the
[handshake's worked example](handshake.md#worked-example).

The header, cleartext and authenticated as AAD:

<!-- vector: packets.datagram.header -->
```
00000000abcd123400000007002625a0
```

| Bytes | Value | Field |
|---|---|---|
| `00` | 0 | `flags`: short form, no key phase |
| `000000` | 0 | reserved |
| `abcd1234` | | `session_id` |
| `00000007` | 7 | `transport_seq` |
| `002625a0` | 2 500 000 | `send_time_us` |

The nonce, 32 zero bits and then packet number 7:

<!-- vector: packets.datagram.nonce -->
```
000000000000000000000007
```

The chunks, before sealing:

<!-- vector: packets.datagram.chunks -->
```
3400020005
```

The complete 37-byte datagram: the header, 5 bytes of ciphertext, and the tag.

<!-- vector: packets.datagram -->
```
00000000abcd123400000007002625a0
2d76a596d909ee8f7a2199664cbd2717
b936eb1329
```

## Clocks

`send_time_us` and the frame header's `capture_time_us` are both drawn from a **monotonic
clock**, in microseconds, truncated to 32 bits. The clock:

- MUST NOT go backwards,
- MUST NOT jump when the system wall clock is adjusted,
- has an unspecified epoch, because only differences are ever used,
- wraps every 4294.967296 seconds, a little under 72 minutes.

Differences MUST be computed with wrapping arithmetic on 32 bits and interpreted as
signed, so that a difference spanning a wrap is correct as long as the true interval is
under about 35 minutes. No interval this protocol measures is anywhere near that.

Whether the clock advances while the system is asleep is not specified, because a
session does not survive system sleep; see [session.md](session.md).

> **Why only differences.** The two endpoints have no synchronised clock and this
> protocol does not try to build one. Everything it measures (round-trip time, one-way
> delay variation, hold time, frame completion) is a difference between two readings of
> the same clock. Nothing ever compares a host timestamp to a client timestamp directly.

## Datagram size

`max_datagram_size` is the size of the **UDP payload**, excluding IP and UDP headers. The
client proposes it in its `INIT`, the host accepts it or lowers it, and it MAY be changed
mid-session ([control.md](control.md)). It MUST be between **256 and 9000** bytes inclusive.
The default is **1200**.

How much of a datagram a media fragment can carry is in [video.md](video.md).

> **Why 1200 by default.** It fits inside the smallest path MTU that can be relied on across
> consumer links and tunnels without fragmentation. An IPv6 path carries at least 1280-byte
> packets, and WireGuard and Tailscale interfaces default to an MTU of 1280 or more, which
> leaves at least 1232 bytes of UDP payload. The protocol proves the path can carry the chosen
> size by padding the `INIT` to exactly `max_datagram_size` and setting don't-fragment, so a
> path that cannot carry it fails during the handshake rather than silently later.

### Path MTU changes

`max_datagram_size` is fixed for the session unless changed by a control message; see
[control.md](control.md). A change applies to datagrams built after it takes effect; a media
frame that has begun transmission keeps the size it started with ([video.md](video.md)).

If a path stops carrying `max_datagram_size` mid-session, the symptom is loss that
retransmission cannot repair, because the retransmissions are the same size. A sender
that observes a frame failing repeatedly at full size SHOULD reduce `max_datagram_size`.
Version 1 defines no automatic path-MTU probe; see [gaps.md](gaps.md).
