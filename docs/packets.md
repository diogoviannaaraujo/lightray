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
| `session_id` | The session this packet belongs to, as assigned in the `RESPONSE`. |
| `transport_seq` | The low 32 bits of a per-direction 64-bit packet counter. |
| `send_time_us` | The sender's monotonic clock in microseconds, truncated to 32 bits. |

The whole 16 bytes are authenticated as additional data. A receiver MUST discard a
packet whose `flags` bit 7 is set, and MUST discard one whose `session_id` does not
match a session it holds — replying with `SESSION_UNKNOWN` only under the conditions in
[handshake.md](handshake.md).

> **Why three reserved bytes and a reserved flag bit.** A congestion controller or an
> FEC scheme needs to signal something on every packet, cheaply and outside the
> encrypted body so that it can be read before decryption. Leaving the room now means
> adding either one later is not a version bump. They cost four bytes out of 1200.

### `transport_seq` and packet numbers

The packet number is a 64-bit counter, one per direction, starting at **0**. It
increments on **every datagram sent**, including retransmissions. Only the low 32 bits
travel.

A receiver reconstructs the full number by choosing the candidate congruent to
`transport_seq` modulo 2³² that is nearest to `expected`, where `expected` is one greater
than the highest packet number it has so far authenticated in this direction:

```
base      = expected & ~0xFFFFFFFF
candidate = base | transport_seq
if candidate + 2^31 <= expected and candidate + 2^32 does not overflow:
    candidate += 2^32
else if candidate > expected + 2^31 and candidate >= 2^32:
    candidate -= 2^32
```

Before any packet has been authenticated, the reconstructed number is `transport_seq`
itself.

> **Why the counter increments on retransmissions.** It makes `transport_seq` a pure
> record of transmission order, which is what lets a receiver report exactly which
> datagrams arrived and in what order without knowing anything about their contents.
> The cost is that the sender must remember what each number carried in order to act on
> that report; see [feedback.md](feedback.md).

### Nonce

```
nonce = iv XOR (0x00000000 ‖ packet_number:u64)
```

The first four bytes of the IV are untouched; the last eight are XORed with the packet
number in big-endian order.

A sender MUST NOT reuse a packet number under a given key. Because the counter
increments on every datagram and never resets within a key, this follows automatically —
but an implementation that rebuilds state on resume MUST ensure the counter restarts
only when the keys do.

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

### Rebinding to a new address

A packet arriving from an address other than the session's current peer rebinds that
session **only if all three hold**:

1. it authenticates,
2. it passes the replay window, and
3. its packet number is strictly greater than any previously authenticated for that
   session.

If the session was not parked, the rebind is silent: no keyframe, no state change, no
event. If it was parked, the rebind is part of resuming; see
[reconnect.md](reconnect.md).

> **Why all three.** The cheapest attack available to someone who can observe traffic but
> not modify it is to capture a valid packet and replay it from elsewhere, hoping to
> redirect the session. Requiring the packet to be strictly newer than everything seen
> defeats that, because a captured packet is by definition not newer. The first two
> conditions alone would not: a captured packet can sit inside the replay window's reach
> if the window has moved on and back.

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
> packet carries a media fragment, a feedback report and one malformed chunk, discarding
> all three throws away two useful pieces of information to punish one. Worse, it makes
> the receiver's behaviour depend on chunk ordering, which nothing else in the protocol
> does.

### Packing

A sender MAY place several chunks in one datagram, subject to two rules:

- A `MEDIA_FRAGMENT` MUST be the only chunk in its datagram.
- The total datagram MUST NOT exceed `max_datagram_size`.

> **Why a media fragment travels alone.** Every fragment except the last of a frame must
> carry exactly `stride` payload bytes, and `stride` is defined as what remains of the
> datagram after the fixed overhead. Anything else sharing the datagram would push the
> fragment over the limit. Control chunks are small and travel together in their own
> datagrams.

## CLOSE (`0x34`)

```
code:u16
```

Ends the session immediately. A sender SHOULD send `CLOSE` when it knows the session is
over — the application asked, or the system is about to sleep — but MUST NOT rely on it
arriving.

A receiver MUST treat the session as closed on receipt, and MUST treat an unassigned
code as `NORMAL`. Close codes are in [registries.md](registries.md).

```
3400020001
```

| Bytes | Value | Field |
|---|---|---|
| `34` | `0x34` | type, `CLOSE` |
| `0002` | 2 | length |
| `0001` | 1 | code, `APP_REQUEST` |

## A complete protected datagram

Host to client, packet number 7, carrying one media fragment alone, sealed
with the `h2c` keys derived in [handshake.md](handshake.md).

Header, cleartext and authenticated as AAD:

```
00000000abcd123400000007002625a0
```

| Bytes | Value | Field |
|---|---|---|
| `00` | 0 | flags: short form, no key phase |
| `000000` | 0 | reserved |
| `abcd1234` | | `session_id` |
| `00000007` | 7 | `transport_seq` |
| `002625a0` | 2 500 000 | `send_time_us` |

Nonce, the host-to-client IV `448d50b586820bc6f220a19c` XORed with packet number 7:

```
448d50b586820bc6f220a19b
```

The chunk sequence, before sealing:

```
01001801010000000700040005047d03010100a0a1a2a3a4a5a6a7
```

This is a `MEDIA_FRAGMENT` of 24 body bytes, carrying the last fragment (index 4 of 5).
Media fragments travel alone, so there is no accompanying `PONG`.
The complete 59-byte datagram is:

```
00000000abcd123400000007002625a0ebc383d03082ccdd54b5b09efa88bc744d9e78c94febca84b0f370b85cae221ab970ef25bdce71a6adeb0c
```

## Clocks

`send_time_us` and the frame header's `capture_time_us` are both drawn from a **monotonic
clock**, in microseconds, truncated to 32 bits. The clock:

- MUST NOT go backwards,
- MUST NOT jump when the system wall clock is adjusted,
- has an unspecified epoch — only differences are ever used,
- wraps every 4294.967296 seconds, a little under 72 minutes.

Differences MUST be computed with wrapping arithmetic on 32 bits and interpreted as
signed, so that a difference spanning a wrap is correct as long as the true interval is
under about 35 minutes. No interval this protocol measures is anywhere near that.

Whether the clock advances while the system is asleep is not specified, because a
session does not survive system sleep; see [reconnect.md](reconnect.md).

> **Why only differences.** The two endpoints have no synchronised clock and this
> protocol does not try to build one. Everything it measures — round-trip time, one-way
> delay variation, hold time, frame completion — is a difference between two readings of
> the same clock. Nothing ever compares a host timestamp to a client timestamp directly.

## Path MTU changes

`max_datagram_size` is fixed for the session unless changed by `RECONFIGURE`; see
[control.md](control.md).

A change takes effect on the **next frame submitted**, never mid-frame. A frame that has
begun transmission MUST continue with the stride it started with, and retransmissions of
that frame MUST use that stride. This is unambiguous to the receiver because `stride`
travels on every fragment.

If a path stops carrying `max_datagram_size` mid-session, the symptom is loss that
retransmission cannot repair, because the retransmissions are the same size. A sender
that observes a frame failing repeatedly at full size SHOULD reduce
`max_datagram_size` by `RECONFIGURE`. Version 0 defines no automatic path-MTU probe;
see [gaps.md](gaps.md).
