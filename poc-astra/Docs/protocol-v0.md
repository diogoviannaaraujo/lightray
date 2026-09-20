# Lightray protocol version 0

This document specifies the byte encoding implemented by this package.
All multibyte integers use unsigned big-endian encoding unless explicitly marked signed.
All lengths count bytes and exclude their own header.
Receivers reject truncated fields, inconsistent lengths, unsupported FEC schemes, zero fragment counts, and impossible fragment indices before copying payloads.
Unknown chunks and unknown TLVs are skipped using their declared lengths.
Reserved bits are ignored on receipt and written as zero.
Version 0 fixes video to HEVC and audio to Opus, 48 kHz, 20 ms packets; microphone streams are mono and playback streams decode as stereo.
The library transports opaque encoded bytes and never encodes or decodes media.

## Handshake and cryptography

The application supplies a pairing identifier (`u64`) and a PSK of at least 32 cryptographically random bytes through an authenticated out-of-band pairing mechanism.
The public demo key in `lightray-demo` is exclusively for local synthetic tests.
The protocol supports one in-band round trip and does not implement rekeying.
Each handshake uses a fresh X25519 private key and each INIT uses a fresh random 96-bit AES-GCM nonce.

INIT is `0x80:u8, version=0:u8, reserved=0:u16, pairing_id:u64, client_public_key:32 bytes, nonce:12 bytes, ciphertext, tag:16 bytes`.
The first 44 bytes are authenticated as AAD.
Derive its AES-128 key using HKDF-SHA256 with input key material PSK, salt equal to the 32 client-public-key bytes, UTF-8 info `lightray-v0 init`, and output length 16.
The INIT plaintext is `parameters_length:u16, parameters, zero padding` and the complete UDP payload must equal the proposed `max_datagram_size`.
Padding is included in the ciphertext and authenticated.
The current accepted datagram-size range is 256 through 9000 bytes, default 1200; a proposed stream table must fit the chosen INIT size.

RESPONSE is `0x81:u8, version=0:u8, session_id:u32, host_public_key:32 bytes, ciphertext, tag:16 bytes`.
The first 38 bytes are AAD and its encrypted plaintext consists directly of parameter TLVs.
Compute `transcript_hash = SHA256(entire INIT datagram || first 38 RESPONSE bytes)`.
Compute X25519 DH using the ephemeral private key and the other endpoint's public key.
For each direction derive 28 bytes with HKDF-SHA256, input key material `PSK || DH`, salt `transcript_hash`, and info `lightray-v0 client` or `lightray-v0 host`.
The first 16 output bytes are the AES-128 key and the final 12 bytes are its IV.
The client label protects client-to-host traffic, and the host label protects host-to-client traffic.
RESPONSE is sealed with the host direction and packet number zero; both directions start protected application traffic at packet number one.
A datagram nonce is the IV XOR the packet number encoded as a 96-bit big-endian integer with four leading zero bytes.
Nonce reuse under a traffic key is forbidden.

Handshake parameter TLVs are `type:u8, length:u16, value`:

| Type | Value |
| --- | --- |
| 1 | Configuration TLVs described below; required |
| 2 | Unix timestamp in seconds, `u64`; required in INIT only |
| 3 | Capability bits `u8` (bit 0 LTR), FEC scheme `u8` (NONE=0); required |
| 4 | Stream entries `(id:u8, kind:u8, direction:u8)`; required |
| 5 | Maximum UDP payload `u16`, identical to the configuration value; required |
| 6 | Optional former session identifier `u32` |
| 7 | Pipeline idle threshold `u64` and grace window `u64`, both in nanoseconds of host running time |
| 8 | Stateless reset token, exactly 16 bytes; required in RESPONSE |

A known TLV may occur only once in the handshake.
INIT timestamps must be within 30 seconds of the host's wall clock; wall-clock timestamps are used only by the handshake replay guard.
Duplicate authenticated INITs within the bounded replay cache produce the same RESPONSE and do not create another session.
The cache holds at most 1024 entries for 60 seconds.
Version mismatches and invalid authentication are silently dropped.
A RESPONSE must not exceed the triggering INIT's length.
An optional former session is adopted only when it is parked and belongs to the same pairing; traffic keys and packet-number space are replaced.

Stream IDs are unique and nonzero, with at most 32 negotiated entries; stream 0 is implicitly the bidirectional reliable control channel.
Kinds are video=1, audio=2, reliable=3, datagram=4; directions are host-to-client=1, client-to-host=2, bidirectional=3.
The default table is host video 1, host audio 2, client microphone 3, client camera 4, bidirectional reliable input 5, and bidirectional datagrams 6.
Sending in the wrong direction or using a chunk with an incompatible stream kind is rejected.
INTRA_REFRESH is reserved and never accepted; NONE is the only FEC scheme.

## Protected datagrams

The 16-byte cleartext header is authenticated as AAD:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 1 | Flags, bit 7 clear; bit 6 key phase reserved |
| 1 | 3 | Reserved |
| 4 | 4 | Session identifier |
| 8 | 4 | Low 32 bits of transport packet number |
| 12 | 4 | Monotonic send time in microseconds modulo 2^32 |

The remainder is AES-GCM ciphertext containing a chunk sequence, followed by its 16-byte detached authentication tag.
Every datagram, including retransmissions, consumes a new per-direction 64-bit number.
Reconstruct the number closest to one greater than the largest authenticated received number, resolving candidates in adjacent 2^32 epochs with a half-window of 2^31.
A 2048-bit replay window admits unseen numbers no more than 2047 behind the highest number.
Only commit replay state after successful authentication.
A newly observed source address can replace the peer address only when the packet authenticates, is not a replay, and exceeds every previously authenticated packet number.
An old but otherwise admissible packet from a different address cannot rebind the session.

SESSION_UNKNOWN is `0x82:u8, session_id:u32, token:16 bytes`.
The token is the first 16 bytes of HMAC-SHA256 with the host secret as key and the big-endian session ID as message.
An endpoint compares the token in constant time against the value received in RESPONSE.
Hosts emit at most one reset per 100 ms globally and only in response to an unknown protected session with a datagram of at least 32 bytes.
A valid reset closes the session and produces `sessionLost`; the application can start a new handshake without repeating pairing.

## Chunks

Chunks are `type:u8, length:u16, body`.

| Type | Name | Body |
| --- | --- | --- |
| 0x01 | MEDIA_FRAGMENT | `stream:u8, flags:u8, frame_id:u32, index:u16, count:u16, stride:u16, ext_length:u8, extensions, payload` |
| 0x02 | RELIABLE | `stream:u8, message_sequence:u32, segment_index:u16, segment_count:u16, payload` |
| 0x03 | DATAGRAM | `stream:u8, payload` |
| 0x10 | FEEDBACK | Packet feedback followed by reliable acknowledgments; see below |
| 0x11 | NACK | `stream:u8` followed by `(frame_id:u32, first:u16, count:u16)` entries |
| 0x12 | FRAME_ACK | Repeated `(stream:u8, frame_id:u32, status:u8)`; received=0, decoded=1 |
| 0x13 | REFRESH_REQUEST | `stream:u8, reason:u8, preferred:u8, last_good:u32, lost_frame:u32, request_id:u32` |
| 0x30 | PING | Sender's monotonic instant in nanoseconds, `u64` |
| 0x31 | PONG | Exact echo of the PING body |
| 0x32 | PARK | Empty |
| 0x33 | RESUME | `flags:u8`, bit 0 indicates decoder lost |
| 0x34 | CLOSE | `code:u16` |

MEDIA_FRAGMENT flag bit 1 identifies retransmission; remaining bits are reserved for metadata hints.
Fragment extensions use `type:u8, length:u8, value`; every sender writes `01 01 00` for FEC NONE.
An unknown extension is ignored, but a recognized FEC extension with a nonzero scheme is rejected.
Indices range from zero to count minus one, stride is nonzero, and every non-last fragment has exactly stride payload bytes.
The last fragment has between one and stride payload bytes and can arrive first.
Placement offset is `index * stride`; all fragments of a frame must agree on count and stride.
Total overhead is 51 bytes, yielding a stride of 1149 at MTU 1200.
The current receiver bounds concurrent reassembly to 128 frames and 32 MiB.

NACK count zero requests the entire frame; otherwise first and count select fragment indices.
Receivers wait at least 1 ms before requesting observed holes and wait one frame interval before requesting an unobserved tail, so pacing does not look like loss.
Retries occur every `max(1.5 * srtt, 2 ms)` until the 50 ms default deadline.
Frame-ID gaps request whole frames; frame IDs are assigned only to nonempty submitted encoded frames.
The retransmit store is bounded by 500 ms and 16 MiB, and identical requests are suppressed within srtt/2.
Each retransmission has a fresh transport packet number.

Reliable messages have independent ordered `u32` sequence spaces per stream.
Only complete messages are delivered, and only in order; duplicates produce another acknowledgment without redelivery.
The implementation limits each channel to 256 outstanding messages, 4096 segments per message, and 4 MiB in each direction.
Retransmission uses `max(srtt + 4*rttvar, 2 ms)` and continues until acknowledgment or connection teardown.

FEEDBACK is `base_sequence:u32, count:u16, base_arrival_us:u32, bitmap:ceil(count/8), arrival_deltas, ack_count:u16, reliable_acks`.
Bitmap bits are least-significant-bit first, where bit i acknowledges base_sequence+i.
Each set bit contributes one signed `i16` arrival delta from base_arrival_us in 4 microsecond units.
Each reliable acknowledgment is `stream:u8, message_sequence:u32` and acknowledges the whole message.
Count zero is valid for a feedback packet containing only reliable acknowledgments.
The acknowledgment trailer makes explicit the definition's requirement to acknowledge reliable channels through FEEDBACK; it is not a separate chunk type.
Receivers may omit the trailer when there are no reliable acknowledgments.
Packet feedback is batched for up to 4 ms and split to fit the negotiated MTU; a new range begins before a signed delta would overflow.
Feedback-only traffic does not elicit feedback, avoiding acknowledgment loops.
RTT is time since the acknowledged send minus the peer's hold time (`feedback_header.send_time_us - acknowledged_arrival_us`, using wrapping arithmetic).

REFRESH_REQUEST reasons are loss=0, decoder_reset=1, resume=2; preference is LTR=0 or IDR=1.
Requests repeat every 20 ms until an admissible recovery frame arrives.
LTR is offered only when negotiated and the sender retains a decoded acknowledgment; decoder reset and parked-session resume force an IDR.
The receiver acknowledges only application-confirmed decoded LTR candidates, at most once per 250 ms per stream, and both sides bound the retained acknowledgment set to 16.

## Frame bytes

Fragmentation treats the frame header plus the application's encoded bytes as one logical byte string.
The frame header is `frame_type:u8, reference_kind:u8, ltr_mark:u8, config_generation:u32, capture_time_us:u32, optional_ref_id:u32, extensions_length:u16, extensions`.
Types are IDR=0, predicted=1, audio=2; references are none=0, previous=1, explicit LTR=2, LTR-any=3.
Only explicit LTR carries the optional reference ID.
Extensions use `type:u8, length:u16, value` and type 1 is CODEC_CONFIG.
Every IDR must include nonempty CODEC_CONFIG bytes containing the HEVC parameter sets required by the application's decoder.
The protocol leaves parameter-set serialization inside this opaque value to the application integration, so both applications must agree on it.
An application cannot feed a predicted frame across a missing previous reference or configuration generation.
LTR-any is accepted only with a retained decoded LTR acknowledgment; IDR establishes a new decode chain.
Frame delivery preserves dependency order while missing fragments are being recovered.
`withPayloadBytes` exposes only the encoded application payload; `withUnsafeBytes` includes the frame header.

## Reliable control stream 0

Configuration TLVs use `type:u8, length:u16, value`:

| Type | Name | Value |
| --- | --- | --- |
| 1 | BITRATE | `u32`, bits/s |
| 2 | BITRATE_FLOOR | `u32`, positive bits/s, no greater than BITRATE |
| 3 | RESOLUTION | `width:u16, height:u16`, both positive |
| 4 | FRAMERATE | `u16`, from 1 through 60 |
| 5 | HDR | `u8`, zero or one |
| 6 | MAX_DATAGRAM_SIZE | `u16`, from 256 through 9000 |

RECONFIGURE is `type=1:u8, request_id:u32, scope_stream:u8, configuration TLVs`.
The current engine uses one shared configuration snapshot; scope 255 means the connection.
RECONFIGURE_RESULT is `type=2:u8, request_id:u32, status:u8, config_generation:u32, applied configuration TLVs`.
STATE is `type=3:u8, flags:u8, config_generation:u32, full configuration TLVs`; flags bit 0 means resume and bit 1 means loss backstop.
Status is applied=0 or rejected=1; unsupported scope and invalid configuration return rejected without changing the snapshot.
Successful reconfiguration increments the configuration generation; resolution and HDR changes request an IDR.
A manual bitrate change clears the loss backstop.
Four consecutive 500 ms feedback windows above 10% loss clamp bitrate to its floor and send STATE with backstop set.
There is no automatic ramp-up.

## Parking and lifecycle

PARK or two seconds of client silence parks a host session.
Parking releases the pacer, reassembly, retransmit, reliable, and LTR state, preserving authentication, packet numbers, the stream table, configuration, address, and instrumentation.
A parked connection has no per-session timeout and sends no keepalives.
The host performs coarse sweeps, emits idle after 60 seconds, and expires the session after 30 minutes of host-running time; both intervals are communicated in the handshake.
The default maximum parked count is 128, with the oldest parked connection evicted first.
A fresh authenticated packet can resume a parked connection; the host sends reliable STATE and requests an IDR for each outbound video stream.
An active-session NAT rebind alone does not require an IDR.
Clients replace their socket before app-driven resume or path-change recovery, and repeat RESUME with exponential backoff until STATE arrives.
System sleep is different from parking: call the runtime's systemSleep hook to close sessions and release traffic keys, then connect on wake.
Monotonic protocol time uses CLOCK_UPTIME_RAW, which does not include sleep.

## Interoperability vectors

Machine-readable vectors are in `Tests/LightrayTests/Vectors/protocol-v0.json`.
They cover protected-header encoding, each chunk type, and a NIST AES-128-GCM known-answer vector with a zero key and IV.
Swift tests load this same file rather than maintaining a separate expected-byte copy.
The header and fragment unit test additionally checks encoding against literal expected bytes.
