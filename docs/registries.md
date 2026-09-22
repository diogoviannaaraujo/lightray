# Registries

Every number that appears on the wire, in one place. Where a range is marked reserved, a
version 0 implementation MUST NOT assign it; a receiver's handling of an unassigned
value is given in [conformance.md](conformance.md).

## Datagram types

The first byte of every datagram distinguishes a handshake packet from a protected one.

| First byte | Meaning |
|---|---|
| `0x00`–`0x7F` | Protected packet. Bit 7 clear marks the short-form header; the remaining bits are the `flags` field described in [packets.md](packets.md). |
| `0x80` | `INIT`, client → host |
| `0x81` | `RESPONSE`, host → client |
| `0x82` | `SESSION_UNKNOWN`, host → client |
| `0x83`–`0xFF` | Reserved |

## Protected header flags

| Bit | Name | Version 0 |
|---|---|---|
| 7 | form | MUST be 0 (short form) |
| 6 | `key_phase` | Reserved for rekeying. MUST be written 0 and ignored. |
| 5–0 | — | Reserved |

## Chunk types

Carried inside the encrypted body of a protected packet.

| Type | Name | Document |
|---|---|---|
| `0x00` | Reserved | — |
| `0x01` | `MEDIA_FRAGMENT` | [video.md](video.md) |
| `0x02` | `RELIABLE` | [input.md](input.md) |
| `0x03` | `DATAGRAM` | [input.md](input.md) |
| `0x04`–`0x0F` | Reserved | — |
| `0x10` | `FEEDBACK` | [feedback.md](feedback.md) |
| `0x11` | `NACK` | [feedback.md](feedback.md) |
| `0x12` | `FRAME_ACK` | [feedback.md](feedback.md) |
| `0x13` | `REFRESH_REQUEST` | [feedback.md](feedback.md) |
| `0x14`–`0x2F` | Reserved | — |
| `0x30` | `PING` | [feedback.md](feedback.md) |
| `0x31` | `PONG` | [feedback.md](feedback.md) |
| `0x32` | `PARK` | [reconnect.md](reconnect.md) |
| `0x33` | `RESUME` | [reconnect.md](reconnect.md) |
| `0x34` | `CLOSE` | [packets.md](packets.md) |
| `0x35`–`0xFF` | Reserved | — |

## Handshake parameter TLVs

Carried in the sealed body of `INIT` and `RESPONSE`. Encoding is `type:u8, length:u16,
value`. See [handshake.md](handshake.md).

| Type | Name | Value | INIT | RESPONSE |
|---|---|---|---|---|
| `0` | Reserved | — | — | — |
| `1` | `CONFIGURATION` | Configuration TLVs (below) | REQUIRED | REQUIRED |
| `2` | `TIMESTAMP` | `u64`, Unix seconds | REQUIRED | MUST NOT appear |
| `3` | `CAPABILITIES` | `capabilities:u8, fec_scheme:u8` | REQUIRED | REQUIRED |
| `4` | `STREAM_TABLE` | Stream entries, 4 bytes each | REQUIRED | REQUIRED |
| `5` | `MAX_DATAGRAM_SIZE` | `u16` | REQUIRED | REQUIRED |
| `6` | `RESUME_SESSION_ID` | `u32` | OPTIONAL | MUST NOT appear |
| `7` | `LIFECYCLE` | `pipeline_idle_after:u64, grace_window:u64`, nanoseconds | OPTIONAL | REQUIRED |
| `8` | `RESET_TOKEN` | 16 bytes | MUST NOT appear | REQUIRED |
| `9`–`255` | Reserved | — | — | — |

## Capability bits

A `u8` bitfield in handshake TLV 3.

| Bit | Name | Version 0 |
|---|---|---|
| 0 | `LTR` | Long-term reference frames. MAY be offered and accepted. |
| 1 | `INTRA_REFRESH` | Reserved. A host MUST NOT accept it. |
| 2 | `FEC` | Reserved. A host MUST NOT accept it. |
| 3–7 | — | Reserved |

> **Why INTRA_REFRESH is reserved rather than absent.** Gradual intra refresh is the
> natural successor to keyframe-based recovery, and reserving the bit now means adding
> it later is a capability negotiation rather than a version bump. Hardware encoders in
> common use do not expose it, so version 0 cannot honour it.

## FEC schemes

| Value | Name | Version 0 |
|---|---|---|
| `0` | `NONE` | The only scheme. MUST be the value on every fragment. |
| `1`–`255` | Reserved | A receiver MUST discard a fragment naming one. |

## Stream kinds

| Value | Name | Direction it normally takes |
|---|---|---|
| `0` | Reserved | — |
| `1` | `VIDEO` | host → client |
| `2` | `AUDIO` | host → client |
| `3` | `INPUT` | client → host |
| `4` | `MIC` | client → host |
| `5` | `CAMERA` | client → host |
| `6` | `DATA` | either |
| `7`–`255` | Reserved | — |

## Stream directions

| Value | Name |
|---|---|
| `0` | Reserved |
| `1` | Host to client |
| `2` | Client to host |
| `3` | Bidirectional |
| `4`–`255` | Reserved |

## Stream classes

The class, not the kind, determines how a stream is treated. See
[video.md](video.md) and [audio.md](audio.md).

| Value | Name | Fragmented | Retransmitted | Decodability-gated | Ordered |
|---|---|---|---|---|---|
| `0` | `MEDIA` | yes | yes, within the deadline | **yes** | by `frame_id` |
| `1` | `REALTIME` | yes | yes, within the deadline | **no** | no |
| `2` | `RELIABLE` | yes, as segments | yes, until acknowledged | no | **yes** |
| `3` | `UNRELIABLE` | no | no | no | no |
| `4`–`255` | Reserved | — | — | — | — |

> **Why class is a separate byte from kind.** The distinction that matters to the
> receiver is not what the bytes represent but how a loss must be handled. Audio and
> video are both media, but withholding an audio packet because an earlier one is
> missing produces a gap the listener hears, where withholding a video frame prevents
> visible corruption. Deriving behaviour from the kind forces that difference to be
> hard-coded; carrying the class lets the stream table say it.

## Default stream table

An application MAY negotiate any table. This one is the conventional assignment and is
what an implementation SHOULD offer when it has no reason to do otherwise.

| id | Kind | Direction | Class |
|---|---|---|---|
| 1 | `VIDEO` | host → client | `MEDIA` |
| 2 | `AUDIO` | host → client | `REALTIME` |
| 3 | `MIC` | client → host | `REALTIME` |
| 4 | `CAMERA` | client → host | `MEDIA` |
| 5 | `INPUT` | bidirectional | `RELIABLE` |
| 6 | `DATA` | bidirectional | `UNRELIABLE` |

Stream `0` is never listed. It is implicitly a bidirectional `RELIABLE` stream carrying
control messages, and is always present.

An application that splits input by device, as [input.md](input.md#splitting-input-by-device)
recommends, replaces stream 5 with one stream per device and adds an `UNRELIABLE` input
stream for high-rate updates.

## Media fragment flags

| Bit | Name | Meaning |
|---|---|---|
| 0 | `KEYFRAME` | This fragment belongs to a frame that needs no prior frame |
| 1 | `RETRANSMISSION` | This fragment has been sent before |
| 2 | `FRAME_START` | `fragment_index` is 0 |
| 3–7 | — | Reserved |

## Frame types

| Value | Name |
|---|---|
| `0` | `IDR` — decodable with no prior frame |
| `1` | `PREDICTED` |
| `2` | `AUDIO` |
| `3`–`255` | Reserved |

## Frame reference kinds

| Value | Name | Carries `ref_frame_id` |
|---|---|---|
| `0` | `NONE` | no |
| `1` | `PREVIOUS` | no |
| `2` | `LTR` | **yes** |
| `3` | `LTR_ANY` | no |
| `4`–`255` | Reserved | — |

## Frame header flags

| Bit | Name | Meaning |
|---|---|---|
| 0 | `LTR_MARK` | The sender offers this frame as a long-term reference candidate |
| 1 | — | Reserved for an intra-refresh-complete marker |
| 2–7 | — | Reserved |

## Frame header extension TLVs

Encoding is `type:u8, length:u16, value`.

| Type | Name | Value |
|---|---|---|
| `0` | Reserved | — |
| `1` | `CODEC_CONFIG` | Decoder configuration; REQUIRED on every `IDR`. See [video.md](video.md). |
| `2`–`255` | Reserved | — |

## Frame acknowledgement status

| Value | Name | Version 0 |
|---|---|---|
| `0` | `RECEIVED` | MAY be sent; a sender MUST NOT treat it as a reference acknowledgement |
| `1` | `DECODED` | The acknowledgement that makes a frame usable as a long-term reference |
| `2`–`255` | Reserved | — |

## Refresh reasons

| Value | Name |
|---|---|
| `0` | `LOSS` — a frame could not be completed |
| `1` | `DECODER_RESET` — the receiver's decoder was lost or rebuilt |
| `2` | `RESUME` — the session has just resumed |
| `3`–`255` | Reserved |

## Refresh preferences

| Value | Name |
|---|---|
| `0` | `LTR` — a frame referencing an acknowledged long-term reference will do |
| `1` | `IDR` — only a keyframe will do |
| `2`–`255` | Reserved |

## Control message types

Carried on reliable stream 0. See [control.md](control.md).

| Value | Name |
|---|---|
| `0` | Reserved |
| `1` | `RECONFIGURE` |
| `2` | `RECONFIGURE_RESULT` |
| `3` | `STATE` |
| `4`–`255` | Reserved |

## Configuration TLVs

Encoding is `type:u8, length:u16, value`. Used both inside handshake TLV 1 and inside
control messages.

| Type | Name | Value | Length | Valid range |
|---|---|---|---|---|
| `0` | Reserved | — | — | — |
| `1` | `BITRATE` | `u32`, bits per second | 4 | 100 000 … 500 000 000 |
| `2` | `BITRATE_FLOOR` | `u32`, bits per second | 4 | 100 000 … `BITRATE` |
| `3` | `RESOLUTION` | `width:u16, height:u16` | 4 | each ≥ 16 |
| `4` | `FRAMERATE` | `u16`, frames per second | 2 | 1 … 240 |
| `5` | `HDR` | `u8`, 0 or 1 | 1 | 0 or 1 |
| `6` | `MAX_DATAGRAM_SIZE` | `u16` | 2 | 256 … 9000 |
| `7` | `CONFIG_GENERATION` | `u32` | 4 | any |
| `8` | `STATE_FLAGS` | `u8` bitfield | 1 | see below |
| `9` | `REJECTED_MASK` | `u32` bitfield | 4 | see below |
| `10`–`255` | Reserved | — | — | — |

`REJECTED_MASK` bit `n` corresponds to configuration TLV type `n + 1`. A set bit means
that field was requested and not applied.

## State flags

| Bit | Name | Meaning |
|---|---|---|
| 0 | `RESUME` | This `STATE` follows a resume |
| 1 | `BACKSTOP` | The bitrate is clamped to the floor by the loss backstop |
| 2–7 | — | Reserved |

## Close codes

| Value | Name |
|---|---|
| `0` | `NORMAL` |
| `1` | `APP_REQUEST` |
| `2` | `TIMEOUT` |
| `3` | `PROTOCOL_VIOLATION` |
| `4` | `VERSION_MISMATCH` |
| `5` | `GOING_AWAY` |
| `6`–`65535` | Reserved |

A receiver that sees an unassigned close code MUST close the session and MUST treat the
code as `NORMAL`.

## Key derivation labels

Exact byte strings, UTF-8, no terminator and no length prefix. See
[handshake.md](handshake.md).

| Label | Used for |
|---|---|
| `lightray-v0 init` | Both the INIT key-derivation context and its HKDF info |
| `lightray-v0 response` | The key that seals the `RESPONSE` body |
| `lightray-v0 client` | Client-to-host traffic keys |
| `lightray-v0 host` | Host-to-client traffic keys |

## Default timings

All are defaults. The lifecycle values are carried in the handshake and are therefore
known to both ends; the rest are local policy and are listed so that independent
implementations behave alike.

| Name | Default | Carried on the wire |
|---|---|---|
| `park_after_silence` | 2 s | no |
| `keepalive_interval` | 250 ms | no |
| `pipeline_idle_after` | 60 s | yes, handshake TLV 7 |
| `grace_window` | 30 min | yes, handshake TLV 7 |
| `ltr_ack_interval` | 250 ms | no |
| `max_acked_ltr` | 16 | no |
| `frame_deadline` | 3 frame intervals | no |
| `recovery_attempt_timeout` | max(2 × frame_deadline, 3 × srtt) | no |
| `tail_wait` | age ≥ 2 frame intervals and inactivity ≥ reorder_window | no |
| `client_liveness_timeout` | 2 s while active or resuming | no |
| `reorder_window` | max(1 ms, srtt / 4) | no |
| `nack_retry_interval` | max(1.5 × srtt, 2 ms) | no |
| `retransmit_store` | 500 ms and 16 MB | no |
| `input_merge_interval` | 1 ms | no |
| `handshake_retry` | 100 ms, doubling, capped at 2 s, at most 8 attempts | no |
