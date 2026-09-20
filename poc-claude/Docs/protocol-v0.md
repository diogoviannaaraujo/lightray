# Lightray wire protocol v0 — normative specification

This document, together with [`golden-vectors.json`](golden-vectors.json), is the
normative definition of the wire format. A Windows client is a separate
implementation against this text, so anything a receiver must do to be correct is
here and not only in a Swift type. Where the Swift in `Sources/` disagrees with
this document, the document is wrong and should be fixed — but check the golden
vectors first, because they are generated from the code and compared on every
test run.

All integers are **big-endian**. Bit 7 is the most significant bit of a byte.

## 1. Version and codecs

The version byte pins the codecs. **v0 means H.265 (HEVC) video and Opus audio**,
Opus at 48 kHz with 20 ms frames, decoded as stereo, with mic streams mono.

Nothing on the wire carries a codec identifier. An Opus packet's TOC byte already
describes its own framing and channel mode, and a mono stream decodes to stereo,
so no audio configuration has to be carried or negotiated. A different codec means
a different wire version: a peer that disagrees fails the version check instead of
negotiating.

`max_datagram_size` is the UDP payload size. The default is 1200; it is
configurable and negotiated in the handshake, and bounded to 512…1452.

## 2. Datagram types

The first byte distinguishes the two families:

| First byte | Meaning |
|---|---|
| bit 7 set | a handshake packet (`0x80` INIT, `0x81` RESPONSE, `0x82` SESSION_UNKNOWN) |
| bit 7 clear | a protected packet (short-form header) |

A receiver can therefore route a datagram before it has any keys.

## 3. Protected packets

```
+--------------------------------+
| cleartext header    16 bytes   |  authenticated as AEAD associated data
+--------------------------------+
| encrypted chunk sequence       |  AES-128-GCM
+--------------------------------+
| authentication tag  16 bytes   |
+--------------------------------+
```

### 3.1 Header

| Offset | Size | Field | Contents |
|---|---|---|---|
| 0 | 1 | `flags` | bit 7 = 0 (short form), bit 6 = `key_phase` (reserved, must be 0 in v0), bits 5–0 reserved and ignored on receipt |
| 1 | 3 | `reserved` | must be zero when sent; ignored on receipt. Room for congestion-control or FEC signalling without a version bump |
| 4 | 4 | `session_id` | assigned by the host in the RESPONSE |
| 8 | 4 | `transport_seq` | low 32 bits of a per-direction 64-bit counter |
| 12 | 4 | `send_time_us` | the sender's monotonic microseconds, truncated to 32 bits. Only deltas are used, so the two peers' clocks need no relation. Wraps every 71.6 minutes |

`transport_seq` increments on **every** datagram, retransmissions included. A
receiver reconstructs the full 64-bit number by choosing the candidate nearest to
`highest_received + 1`, as QUIC does.

### 3.2 Protection

The nonce is the 12-byte direction IV XORed with the full 64-bit packet number,
right-aligned:

```
nonce[0..3]  = iv[0..3]
nonce[4..11] = iv[4..11] XOR big_endian_u64(packet_number)
```

The 16-byte header is the associated data. The tag is appended to the ciphertext
(a detached tag in CryptoKit's terms). A receiver that fails to open a datagram
drops it silently and increments a counter: a wrong PSK, a tampered header, a
tampered body and a wrong packet number are indistinguishable on the wire, which
is the point.

### 3.3 Replay window

A receiver keeps a **2048-bit** sliding window over reconstructed packet numbers,
anchored at the highest accepted number. A number that is already recorded, or
that has fallen out of the window, is rejected. At 1 Gbps that tolerates 19.7 ms
of reordering, and 393 ms at 50 Mbps.

### 3.4 Chunk sequence

The decrypted payload is a sequence of chunks:

```
type:u8  length:u16  body[length]
```

- **A `type` byte of 0 ends the sequence.** Type 0 is reserved and never written,
  so trailing zero padding reads as the end.
- **Unknown types must be skipped** using `length`. This is what lets a later
  version add chunks without a version bump.
- Fewer than 3 bytes remaining also ends the sequence.

| Type | Name | §  |
|---|---|---|
| 0x01 | MEDIA_FRAGMENT | 3.5 |
| 0x02 | RELIABLE | 3.6 |
| 0x03 | DATAGRAM | 3.7 |
| 0x10 | FEEDBACK | 3.8 |
| 0x11 | NACK | 3.9 |
| 0x12 | FRAME_ACK | 3.10 |
| 0x13 | REFRESH_REQUEST | 3.11 |
| 0x30 | PING | 3.12 |
| 0x31 | PONG | 3.12 |
| 0x32 | PARK | 3.13 |
| 0x33 | RESUME | 3.13 |
| 0x34 | CLOSE | 3.13 |

A MEDIA_FRAGMENT never shares a datagram with another chunk, because every
non-last fragment of a frame must carry exactly `stride` payload bytes (§3.5).

### 3.5 MEDIA_FRAGMENT (0x01)

```
stream:u8
flags:u8            bit0 keyframe, bit1 retransmission, bit2 frame_start, rest reserved
frame_id:u32
fragment_index:u16
fragment_count:u16
stride:u16
ext_len:u8
ext TLVs[ext_len]   type:u8 len:u8 value[len]
payload[...]        the rest of the chunk
```

13 bytes of header, then the ext TLVs, then payload. v0 always writes exactly one
ext TLV, the FEC scheme:

```
type 0x01, len 1, value: 0x00 = NONE
```

A receiver that sees a FEC scheme it does not implement must drop the fragment.

**Reassembly.** Fragment `i` occupies bytes `[i × stride, (i+1) × stride)` of the
frame's byte stream, so a receiver places any fragment the moment it arrives —
including a last fragment that arrives before any other, and across a mid-session
`MAX_DATAGRAM_SIZE` change. `stride` is on the wire precisely so this never has to
be inferred. The frame is complete when all `fragment_count` fragments have
arrived; its exact length is `(fragment_count − 1) × stride` plus the last
fragment's payload length.

`fragment_count` must be greater than zero, `fragment_index` must be less than
`fragment_count`, and `stride` must be greater than zero. Otherwise the chunk is
malformed.

**`frame_id`** is assigned by the sender's protocol layer, and **only for frames
that produced bytes**. A low-latency encoder under a tight budget skips frames
outright and emits nothing for them, so an id assigned per capture would leave
gaps indistinguishable from whole-frame loss. Capture cadence stays visible
through the frame header's `capture_time_us`.

**Payload budget at 1200 bytes:** 16 header + 16 tag + 3 chunk header + 13
fragment header + 3 FEC TLV = 51 bytes of overhead, leaving **1149 payload bytes**
(95.75% of the datagram).

### 3.6 RELIABLE (0x02)

```
stream:u8
msg_seq:u32
seg_index:u16
seg_count:u16
payload[...]
```

Ordered and acknowledged. **Stream 0 is the control channel** (§4).

`msg_seq` starts at 0 for each channel and increments per message. A receiver
delivers message `n` only once every one of its `seg_count` segments has arrived
and every message before it has been delivered.

**Acknowledgement rides on FEEDBACK** rather than a second ack scheme: the packet
that carried a segment is reported received, so the segment is acked. An unacked
segment is resent after an RTO of `srtt + 4·rttvar`, floored at 20 ms and capped
at 1 s.

A resume restarts both `msg_seq` and the receiver's expectation at 0. That is safe
because a datagram sent before the resume cannot reach the channel afterwards: on
a plain resume the replay window survives and already holds its packet number, and
after a re-handshake the keys are new.

### 3.7 DATAGRAM (0x03)

```
stream:u8
payload[...]
```

Unreliable and unordered. Delivered as it arrives or not at all.

### 3.8 FEEDBACK (0x10)

```
base_seq:u32
count:u16
base_arrival_us:u32
bitmap[ceil(count/8)]        bit for base_seq+i, MSB first within each byte
deltas[popcount(bitmap)]     i16 each, in units of 4 µs
```

The report covers `base_seq … base_seq+count-1`. A set bit means the packet
arrived. `base_arrival_us` is the arrival time of the **first** received packet in
the range, on the reporter's clock.

One `i16` delta follows per received packet, in increasing sequence order. The
first received packet's delta is relative to `base_arrival_us` and is therefore
always 0; each later delta is relative to the previous received packet's arrival.
A delta spans ±131.068 ms, so an arrival gap longer than that cannot be encoded
and is clamped.

**RTT** comes from the hold time, with no PING needed: the reporter's own
`send_time_us` in the enclosing header minus the arrival it reports for the newest
received packet is how long it sat on the report. The original sender computes
`rtt = (now − send_time_of_that_packet) − hold`. Both terms of `hold` come from
the reporter's clock, so the two clocks never have to agree.

One 1200-byte datagram covers at most **543** reported packets, so a high-rate flow
needs several feedback datagrams per report period: about 58/s at 300 Mbps and
192/s at 1 Gbps if every packet is reported.

### 3.9 NACK (0x11)

```
stream:u8
entries[...]     frame_id:u32  first:u16  count:u16
```

`count == 0` means **the whole frame**, used when no fragment of it has arrived so
its fragment count is unknown.

A receiver detects loss three ways: a hole below the highest fragment index it has
seen for a frame; a `frame_id` gap, which is a whole-frame loss; and a tail-loss
timer for indices above the highest seen, which only matters while the last
fragment is missing.

**A hole above the highest index seen is not loss.** The sender's pacer spreads a
frame across its interval, so those fragments have simply not been sent yet.

Default timing: the first NACK after the reorder window (≥ 1 ms), retried every
`max(1.5·srtt, 2 ms)`, given up at the frame deadline (3 frame intervals).

A sender answers from its retransmit store (500 ms or 16 MB, whichever binds
first), suppressing a repeat of the same fragment within `srtt/2`. Each
retransmission gets a **new `transport_seq`** and sets the retransmission flag. If
the frame has already been evicted, the only honest answer is a refresh (§3.11).

### 3.10 FRAME_ACK (0x12)

```
entries[...]     stream:u8  frame_id:u32  status:u8
```

`status`: 0 = received, 1 = decoded. **`decoded` on an LTR-marked frame is the LTR
ack**, and the receiver must only send it for a frame its decoder actually
decoded — that is what makes `ref_kind = ltrAny` sound.

A receiver acks at most one LTR-marked frame per `ltr_ack_interval` (default
250 ms), which keeps FRAME_ACK traffic at about 4/s instead of the frame rate. A
sender retains the last `max_acked_ltr` acks (default 16), which bounds the set it
can offer an encoder.

### 3.11 REFRESH_REQUEST (0x13)

```
stream:u8
reason:u8           0 loss, 1 decoder_reset, 2 resume
preferred:u8        0 ltr, 1 idr
last_good_frame:u32
lost_frame:u32
req_id:u32
```

Sent when a frame is lost and the decoder is still alive, and repeated until a
recovery frame arrives. If LTR was negotiated and the sender holds at least one
ack, it offers its encoder the whole retained set and the encoder chooses;
otherwise the answer is an IDR.

The encoder does not report which reference it used, so the refresh frame is
marked `ref_kind = ltrAny` and the receiver accepts it unconditionally. That is
sound because the receiver only ever acked frames it decoded.

### 3.12 PING (0x30) / PONG (0x31)

```
PING:  id:u32
PONG:  id:u32  hold_us:u32
```

Idle keepalive and RTT. `hold_us` is how long the responder held the PING, so
`rtt = (now − ping_sent) − hold_us` is computed entirely on the initiator's clock.
A client sends a PING only when the link is otherwise silent; FEEDBACK counts as
traffic.

### 3.13 PARK (0x32) / RESUME (0x33) / CLOSE (0x34)

```
PARK:    (empty)
RESUME:  flags:u8    bit0 decoder_lost
CLOSE:   code:u16
```

Close codes: 0 normal, 1 app request, 2 timeout, 3 protocol violation, 4 version
mismatch, 5 going away.

## 4. Control messages (reliable stream 0)

```
msg_type:u8      0x01 RECONFIGURE, 0x02 RECONFIGURE_RESULT, 0x03 STATE
req_id:u32
scope_stream:u8
TLVs[...]        type:u8  len:u16  value[len]
```

A `type` byte of 0 ends the TLVs. Unknown types must be skipped.

| Type | Field | Value |
|---|---|---|
| 0x20 | BITRATE | u32 bits per second, accepted range 100 kbps…500 Mbps |
| 0x21 | BITRATE_FLOOR | u32, must be ≤ BITRATE |
| 0x22 | RESOLUTION | u16 width, u16 height, each ≥ 16 |
| 0x23 | FRAMERATE | u16 fps, 1…240 |
| 0x24 | HDR | u8, 0 or 1 |
| 0x03 | MAX_DATAGRAM_SIZE | u16, 512…1452 |
| 0x25 | CONFIG_GENERATION | u16 |
| 0x26 | STATE_FLAGS | u8: bit0 resume, bit1 backstop |
| 0x27 | REJECTED_MASK | u32, bit per rejected TLV type |

RECONFIGURE is the one path for every parameter; a manual bitrate change rides it.
There is no codec TLV, because the codec is fixed by the wire version.

A receiver applies what it accepts, bumps `config_generation` if anything actually
changed, and replies with RECONFIGURE_RESULT carrying the values now in force plus
a `REJECTED_MASK` for anything out of range. STATE is a full snapshot, sent on
resume with the `resume` flag and whenever the loss backstop engages with the
`backstop` flag.

## 5. Frame header

The sender logically prepends this to each frame's bytes, so fragmentation stays
payload-agnostic and zero-copy. It is part of the fragmented byte stream, not a
separate chunk.

```
frame_type:u8          0 idr, 1 predicted
ref_kind:u8            0 none, 1 previous, 2 ltr, 3 ltrAny
flags:u8               bit0 ltr_mark
config_generation:u16
capture_time_us:u32
ref_frame_id:u32       present if and only if ref_kind == 2 (ltr)
ext_len:u16
ext TLVs[ext_len]      type:u8  len:u16  value[len]
frame bytes[...]
```

Ext TLV types: `0x01 CODEC_CONFIG`, `0x02` reserved for an intra-refresh-complete
flag (never written in v0 — VideoToolbox has no intra-refresh property).

**Every IDR must carry `CODEC_CONFIG`.** HEVC parameter sets (VPS, SPS and PPS; 81
bytes on the encoders measured, with 4-byte NAL lengths) are not in-band in slice
data and no decoder can be constructed without them. They change only with
resolution or profile, and both force an IDR, so the set a receiver needs is
always attached to the frame that needs it: a joining or rebuilt decoder never
waits on a separate message, and a `decoder_lost` resume needs nothing beyond the
recovery IDR itself.

`ref_kind = ltrAny` carries **no** `ref_frame_id`: the encoder chose from the acked
set and does not report which one.

**Decodability.** A receiver must not hand the decoder a frame whose references are
missing. With two frames lost and no refresh, the H.264 decoder returns success
and outputs corrupted frames, and HEVC returns an error; neither is acceptable.
The rules, for a stream of class `media`:

| `frame_type` / `ref_kind` | Decodable when |
|---|---|
| `idr` | always; it reopens the gate |
| `none` | always |
| `previous` | the frame with id one less was delivered |
| `ltr` | `ref_frame_id` is in the set this receiver acked as decoded, or is the last frame delivered |
| `ltrAny` | the acked set is non-empty |

A stream of class `realtime` is **not** gated: its frames are independent — an Opus
packet references nothing — so a gap is reported to the app for packet-loss
concealment and the stream carries on.

Frames are delivered in `frame_id` order. A frame that completes before its
predecessor waits until the predecessor arrives or its own deadline passes, rather
than being discarded: a small predicted frame often finishes before the large IDR
in front of it.

## 6. Handshake

A 1-RTT, NNpsk0-shaped handshake using an app-supplied pairing PSK plus X25519
ephemeral keys.

### 6.1 INIT (0x80), client → host

Cleartext prefix, 44 bytes, authenticated as the AEAD associated data:

```
type:u8 = 0x80
version:u8
reserved:u16        must be zero
pairing_id:u64
client_ephemeral[32]    X25519 public key
```

Then the sealed body: ciphertext ‖ 16-byte tag, filling the datagram exactly.

**The datagram is padded to `max_datagram_size`, and the padding goes inside the
sealed body.** So the sealed length is implied by the datagram length and no field
has to carry it, and the padding is authenticated — an attacker cannot strip it to
make a smaller packet that still opens. The padding is zero bytes, which the TLV
parser reads as the end of the TLVs.

The padding both limits amplification — the RESPONSE is roughly a seventh of the
size — and proves the path MTU, because the socket sets don't-fragment.

Body TLVs (`type:u8 len:u16 value`):

| Type | Field |
|---|---|
| 0x01 | CAPABILITIES, u32: bit0 LTR, bit1 INTRA_REFRESH (reserved), bit2 FEC |
| 0x02 | STREAM_TABLE, 4 bytes per stream: `id:u8 kind:u8 direction:u8 class:u8` |
| 0x03 | MAX_DATAGRAM_SIZE, u16 |
| 0x04 | CLIENT_TIMESTAMP, u64 microseconds on the client's own clock |
| 0x05 | RESUME_SESSION_ID, u32, optional |
| 0x20 | the initial configuration, as a nested control-message body |

Stream `kind`: 0 video, 1 audio, 2 input, 3 mic, 4 camera, 5 data.
`direction`: 0 host→client, 1 client→host.
`class`: 0 media, 1 realtime, 2 reliable, 3 unreliable.

**Replay.** The host rejects an INIT whose `client_ephemeral` it has already seen.
The ephemeral is fresh for every handshake, which is a stronger guard than a
timestamp and survives a client reboot resetting its monotonic clock.
`CLIENT_TIMESTAMP` is carried and surfaced for a host that wants to reject stale
INITs on a trusted clock.

**Version mismatch.** The host drops the packet silently and increments a counter.

### 6.2 RESPONSE (0x81), host → client

Cleartext prefix, 38 bytes, authenticated:

```
type:u8 = 0x81
version:u8
session_id:u32
host_ephemeral[32]
```

Then the sealed body. Not padded, so its length is the datagram's.

| Type | Field |
|---|---|
| 0x01 | ACCEPTED_CAPABILITIES, u32. `INTRA_REFRESH` is never accepted in v0 |
| 0x02 | STREAM_TABLE, as in INIT |
| 0x03 | MAX_DATAGRAM_SIZE, u16, the host's choice |
| 0x06 | PIPELINE_IDLE_AFTER, u32 milliseconds |
| 0x07 | GRACE_WINDOW, u32 milliseconds |
| 0x08 | RESET_TOKEN, 16 bytes |
| 0x09 | FEC_SCHEMES, u8 list; v0 is `[0x00]` = NONE only |
| 0x26 | STATE_FLAGS, u8: bit0 set when the host adopted a parked session |
| 0x20 | the accepted configuration, as a nested control-message body |

### 6.3 SESSION_UNKNOWN (0x82), host → client

```
type:u8 = 0x82
session_id:u32
token[16]
```

21 bytes, always smaller than the 32-byte minimum protected datagram that triggers
it, so it cannot be used for amplification. It is rate-limited (20/s by default).

The token is `HMAC-SHA256(host_secret, big_endian_u32(session_id))` truncated to
16 bytes — the same value the RESPONSE handed over as `RESET_TOKEN`. A client
compares them, so it can tell a real host from an off-path forgery without holding
any host secret. It then reports the session lost and re-handshakes.

### 6.4 Key schedule

```
transcript0 = SHA256("lightray/v0 init" || version || be_u64(pairing_id) || client_ephemeral)
init_keys   = HKDF-SHA256(ikm: psk, salt: transcript0, info: "lightray init", L: 28)

transcript1 = SHA256(transcript0 || host_ephemeral || be_u32(session_id))
prk         = HKDF-Extract(salt: transcript1, ikm: X25519(client_e, host_e) || psk)
resp_keys   = HKDF-Expand(prk, info: "lightray response", L: 28)
c2h_keys    = HKDF-Expand(prk, info: "lightray c2h",      L: 28)
h2c_keys    = HKDF-Expand(prk, info: "lightray h2c",      L: 28)
```

Every 28-byte output is `key[16] || iv[12]`. All labels are ASCII with no
terminator.

The INIT body is sealed with `init_keys` and the RESPONSE body with `resp_keys`,
each using the IV itself as the nonce, because each key protects exactly one
packet. Traffic uses `c2h_keys` and `h2c_keys` with the nonce of §3.2.

`init_keys` depends only on the PSK and the transcript, which is what lets the host
open the INIT before it has an ephemeral of its own. It has no forward secrecy,
which is why the INIT body carries nothing but capabilities and configuration.

## 7. Reconnect

**Host parking.** A host parks a session on receiving PARK, or after
`park_after_silence` (default 2 s). Parking releases the retransmit store, pacer
queues, reassembly state and LTR ack state at once: none of it can reach an absent
peer, and a resume forces an IDR that would discard it anyway. What remains — keys,
packet-number and replay state, the stream table, the config snapshot, rebind
state and statistics — is under 1 KB plus statistics, and costs no processing:
nothing is sent to a parked session and no per-session timer runs, so expiry is one
coarse sweep over the parked set.

After `pipeline_idle_after` (default 60 s) the host tells its app to tear the
encoder and capture down. The session is untouched, so a client returning later
still resumes; it needs a fresh encoder only because a resume forces an IDR
regardless.

`grace_window` (default 30 minutes of host-running time) ends the session and
discards its keys. A window that long is affordable only because parking released
the media buffers.

**Rebind rule.** A packet from a new address rebinds the session only if **all
three** hold: it authenticates, it passes the replay window, and its
`transport_seq` is higher than any seen before. An old packet from a new address —
the shape an off-path attacker can most easily produce — moves nothing. If the
session was not parked, the rebind is silent and needs no IDR, which is what makes
NAT rebinding and Wi-Fi roaming invisible.

**Resume from parked.**

1. Flush pacer queues, NACK state and reassembly state in both directions.
2. Send STATE reliably, with the `resume` flag.
3. Force an IDR on every outbound video stream. **A resume is always an IDR.**

**Client side.** The app decides what counts as going idle. `park()` sends PARK;
`resume(decoder_lost:)` recreates the socket, so the host sees a new source port,
and sends RESUME repeated with backoff until STATE arrives. A client also replaces
its socket on a socket error or a network path change.

**System sleep is not a park.** A lid close ends the session: the client sends
CLOSE if it still can and re-handshakes on wake, which costs one round trip and an
IDR with no re-pairing. That is why the monotonic clock need not advance across
sleep, and why no keys sit in a hibernation image.

A re-handshake may carry `RESUME_SESSION_ID`. If the host still has that session
parked under the same pairing, it adopts it with new keys: the session id, stream
table, configuration and statistics survive, while the packet-number space and
replay window restart, because a nonce is only unique within one key.
