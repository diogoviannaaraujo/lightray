# Registries

Every number that appears on the wire, in one place. Where a range is marked reserved, an
implementation MUST NOT assign it; a receiver's handling of an unassigned value is given in
[conformance.md](conformance.md). A number that an earlier version used and this one retired is
never assigned again.

A section marked *Version 0, pending* is carried unchanged from version 0 until the document
that owns it is rewritten for version 1.

## Datagram types

The first byte of every datagram distinguishes a handshake packet from a protected one.

| First byte | Meaning |
|---|---|
| `0x00`–`0x7F` | Protected packet. Bit 7 clear marks the short-form header; the remaining bits are the `flags` field described in [packets.md](packets.md). |
| `0x80` | `INIT`, client → host |
| `0x81` | `RESPONSE`, host → client |
| `0x82` | `SESSION_UNKNOWN`, host → client |
| `0x83`–`0xFF` | Reserved |

The second byte of every handshake packet is the version, 1.

## Protected header flags

| Bit | Name | Version 1 |
|---|---|---|
| 7 | form | MUST be 0 (short form) |
| 6 | `key_phase` | Reserved for rekeying. MUST be written 0 and ignored. |
| 5–0 | — | Reserved |

## Chunk types

Carried inside the encrypted body of a protected packet.

| Type | Name | Document |
|---|---|---|
| `0x00` | `PADDING` | [packets.md](packets.md) |
| `0x01` | `MEDIA_FRAGMENT` | [video.md](video.md) |
| `0x02` | `RELIABLE` | [input.md](input.md) |
| `0x03` | `DATAGRAM` | [input.md](input.md) |
| `0x04` | `AUDIO_FRAME`, planned | [audio.md](audio.md) |
| `0x05`–`0x0F` | Reserved | — |
| `0x10` | `FEEDBACK` | [feedback.md](feedback.md) |
| `0x11` | `NACK` | [feedback.md](feedback.md) |
| `0x12` | `FRAME_ACK` | [feedback.md](feedback.md) |
| `0x13` | `REFRESH_REQUEST` | [feedback.md](feedback.md) |
| `0x14` | `RECEIVER_STATS`, planned | [feedback.md](feedback.md) |
| `0x15`–`0x2F` | Reserved | — |
| `0x30` | `PING` | [feedback.md](feedback.md) |
| `0x31` | `PONG` | [feedback.md](feedback.md) |
| `0x32` | `PARK` | [session.md](session.md) |
| `0x33` | `RESUME` | [session.md](session.md) |
| `0x34` | `CLOSE` | [packets.md](packets.md) |
| `0x35`–`0xFF` | Reserved | — |

A number marked *planned* is set aside for a chunk that its document will define. Until then a
receiver treats it as unassigned.

## Handshake parameter TLVs

Carried in the sealed payloads of `INIT` and `RESPONSE`. Encoding is `type:u8, length:u16,
value`. See [handshake.md](handshake.md#parameters).

| Type | Name | Value | INIT | RESPONSE |
|---|---|---|---|---|
| `0` | Reserved | — | — | — |
| `1` | `SETTINGS` | Defined in [modes.md](modes.md) | | |
| `2` | `TIMESTAMP` | `u64`, Unix seconds | REQUIRED | MUST NOT appear |
| `3` | `CAPABILITIES` | Defined in [video.md](video.md) | | |
| `4` | `STREAM_TABLE` | Stream entries, 4 bytes each | REQUIRED | REQUIRED |
| `5` | `MAX_DATAGRAM_SIZE` | `u16` | REQUIRED | REQUIRED |
| `6` | `RESUME_SESSION_ID` | `u32` | OPTIONAL | MUST NOT appear |
| `7` | `LIFECYCLE` | Defined in [session.md](session.md) | | |
| `8` | Retired | Version 0's `RESET_TOKEN`; the token is now a fixed field of the `RESPONSE` | — | — |
| `9`–`255` | Reserved | — | — | — |

## Streams

The stream table's entries; see [handshake.md](handshake.md#stream_table-4). What the values
mean is in [packets.md](packets.md#streams).

### Stream kinds

| Value | Name | Direction it normally takes |
|---|---|---|
| `0` | Reserved | — |
| `1` | `VIDEO` | host → client |
| `2` | `AUDIO` | host → client |
| `3` | `INPUT` | client → host |
| `4` | `MIC` | client → host |
| `5` | Reserved for a camera | — |
| `6` | `DATA` | either; kept or retired when [input.md](input.md) is rewritten |
| `7`–`255` | Reserved | — |

### Stream directions

| Value | Name |
|---|---|
| `0` | Reserved |
| `1` | Host to client |
| `2` | Client to host |
| `3` | Bidirectional |
| `4`–`255` | Reserved |

### Stream classes

| Value | Name |
|---|---|
| `0` | `MEDIA` |
| `1` | `REALTIME` |
| `2` | `RELIABLE` |
| `3` | `UNRELIABLE` |
| `4`–`255` | Reserved |

### Default stream table

*Interim, until [input.md](input.md) gives each input device a stream of its own and adds
the cursor channel. Version 0's table offered a camera, which version 1 only reserves.*

An application MAY negotiate any table. This one is the conventional assignment and is
what an implementation SHOULD offer when it has no reason to do otherwise. The handshake's
worked example uses it.

| id | Kind | Direction | Class |
|---|---|---|---|
| 1 | `VIDEO` | host → client | `MEDIA` |
| 2 | `AUDIO` | host → client | `REALTIME` |
| 3 | `MIC` | client → host | `REALTIME` |
| 4 | `INPUT` | client → host | `RELIABLE` |

Stream `0` is never listed. It is implicitly a bidirectional `RELIABLE` stream carrying
control messages, and is always present.

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

## Names and labels

Exact byte strings, ASCII, with no terminator and no length prefix. See
[handshake.md](handshake.md).

| String | Used for |
|---|---|
| `Noise_NNpsk0_25519_AESGCM_SHA256` | The Noise protocol name, and so the handshake's initial `h` and `ck` |
| `lightray-v1` | The start of the prologue: `"lightray-v1" ‖ INIT[0..12)` |
| `lightray-v1 reset` | The start of the message whose HMAC is a reset token |

## Default timings and limits

All are defaults. None is carried on the wire; they are listed so that independent
implementations behave alike.

| Name | Default | Document |
|---|---|---|
| `handshake_retry` | 100 ms, doubling, capped at 2 s; at most 8 transmissions, the first included | [handshake.md](handshake.md#retransmission) |
| `timestamp_window` | ±30 s | [handshake.md](handshake.md#replay-protection) |
| `init_cache` | at least 1024 entries, each kept at least 60 s | [handshake.md](handshake.md#replay-protection) |
| `session_unknown_rate` | a bucket of 20, refilled at 20 per second | [handshake.md](handshake.md#session_unknown-0x82-host--client) |
| `early_packet_buffer` | 64 protected packets | [handshake.md](handshake.md#traffic-keys) |
| `replay_window` | 2048 packets | [packets.md](packets.md#replay-window) |
| `unvalidated_send_limit` | 3 × the bytes received from the address | [packets.md](packets.md#validating-a-new-address) |

## Version 0, pending

Everything below is carried unchanged from version 0 until the document named in each section
is rewritten.

### FEC schemes

*Pending [video.md](video.md), which adds Reed–Solomon (RFC 5510) as scheme 1.*

| Value | Name | Version 0 |
|---|---|---|
| `0` | `NONE` | The only scheme. MUST be the value on every fragment. |
| `1`–`255` | Reserved | A receiver MUST discard a fragment naming one. |

### Capability bits

*Pending [video.md](video.md), which redefines the `CAPABILITIES` parameter.*

A `u8` bitfield in handshake TLV 3.

| Bit | Name | Version 0 |
|---|---|---|
| 0 | `LTR` | Long-term reference frames. MAY be offered and accepted. |
| 1 | `INTRA_REFRESH` | Reserved. A host MUST NOT accept it. |
| 2 | `FEC` | Reserved. A host MUST NOT accept it. |
| 3–7 | — | Reserved |

### Media fragment flags

*Pending [video.md](video.md).*

| Bit | Name | Meaning |
|---|---|---|
| 0 | `KEYFRAME` | This fragment belongs to a frame that needs no prior frame |
| 1 | `RETRANSMISSION` | This fragment has been sent before |
| 2 | `FRAME_START` | `fragment_index` is 0 |
| 3–7 | — | Reserved |

### Frame types

*Pending [video.md](video.md) and [audio.md](audio.md).*

| Value | Name |
|---|---|
| `0` | `IDR`: decodable with no prior frame |
| `1` | `PREDICTED` |
| `2` | `AUDIO` |
| `3`–`255` | Reserved |

### Frame reference kinds

*Pending [video.md](video.md).*

| Value | Name | Carries `ref_frame_id` |
|---|---|---|
| `0` | `NONE` | no |
| `1` | `PREVIOUS` | no |
| `2` | `LTR` | **yes** |
| `3` | `LTR_ANY` | no |
| `4`–`255` | Reserved | — |

### Frame header flags

*Pending [video.md](video.md).*

| Bit | Name | Meaning |
|---|---|---|
| 0 | `LTR_MARK` | The sender offers this frame as a long-term reference candidate |
| 1 | — | Reserved for an intra-refresh-complete marker |
| 2–7 | — | Reserved |

### Frame header extension TLVs

*Pending [video.md](video.md).*

Encoding is `type:u8, length:u16, value`.

| Type | Name | Value |
|---|---|---|
| `0` | Reserved | — |
| `1` | `CODEC_CONFIG` | Decoder configuration; REQUIRED on every `IDR`. See [video.md](video.md). |
| `2`–`255` | Reserved | — |

### Frame acknowledgement status

*Pending [feedback.md](feedback.md).*

| Value | Name | Version 0 |
|---|---|---|
| `0` | `RECEIVED` | MAY be sent; a sender MUST NOT treat it as a reference acknowledgement |
| `1` | `DECODED` | The acknowledgement that makes a frame usable as a long-term reference |
| `2`–`255` | Reserved | — |

### Refresh reasons

*Pending [feedback.md](feedback.md).*

| Value | Name |
|---|---|
| `0` | `LOSS`: a frame could not be completed |
| `1` | `DECODER_RESET`: the receiver's decoder was lost or rebuilt |
| `2` | `RESUME`: the session has just resumed |
| `3`–`255` | Reserved |

### Refresh preferences

*Pending [feedback.md](feedback.md).*

| Value | Name |
|---|---|
| `0` | `LTR`: a frame referencing an acknowledged long-term reference will do |
| `1` | `IDR`: only a keyframe will do |
| `2`–`255` | Reserved |

### Control message types

*Pending [control.md](control.md).*

Carried on reliable stream 0.

| Value | Name |
|---|---|
| `0` | Reserved |
| `1` | `RECONFIGURE` |
| `2` | `RECONFIGURE_RESULT` |
| `3` | `STATE` |
| `4`–`255` | Reserved |

### Configuration TLVs

*Pending [control.md](control.md) and [modes.md](modes.md), which replace them with the
settings carried in `SETTINGS`.*

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

### State flags

*Pending [control.md](control.md).*

| Bit | Name | Meaning |
|---|---|---|
| 0 | `RESUME` | This `STATE` follows a resume |
| 1 | `BACKSTOP` | The bitrate is clamped to the floor by the loss backstop |
| 2–7 | — | Reserved |

### Timings

*Pending the documents named. Version 1 removes `tail_wait`: tail loss is detected from gaps in
`transport_seq`.*

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
