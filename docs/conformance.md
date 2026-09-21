# Conformance

## Handling bad input

Every malformed or unexpected input has exactly one defined outcome. "Discard" means the
named thing is dropped and nothing else is affected. "Count" means an implementation
SHOULD maintain a counter for the event; the counters are how an operator diagnoses a
link that is nearly working.

### Datagram level

| Condition | Action |
|---|---|
| Fewer than 1 byte | Discard |
| First byte `0x83`–`0xFF` | Discard, count |
| Handshake packet with an unimplemented version | Discard, count. MUST NOT reply |
| Protected packet shorter than 32 bytes | Discard, count |
| Protected packet with `flags` bit 7 set | Discard, count |
| `session_id` names no session, packet ≥ 32 bytes | Send `SESSION_UNKNOWN`, subject to rate limiting |
| `session_id` names no session, packet < 32 bytes | Discard, count. MUST NOT reply |
| Authentication fails | Discard, count. MUST NOT change any state |
| Packet number already seen, or more than 2047 behind | Discard, count |
| Authenticated packet from a new address, not strictly newest | Discard, count. MUST NOT rebind |

### Handshake

| Condition | Action |
|---|---|
| `INIT` length ≠ its declared `MAX_DATAGRAM_SIZE` | Discard, count |
| `INIT` outside 256–9000 bytes | Discard, count |
| `INIT` names an unknown `pairing_id` | Discard, count |
| `INIT` timestamp more than 30 s from the host's clock | Discard, count |
| `INIT` digest already in the replay cache | **Resend the cached `RESPONSE`.** MUST NOT create a session |
| `params_len` exceeds the plaintext | Discard, count |
| A TLV of type 1–8 appears twice | Reject the handshake |
| TLV 1, 3, 4 or 5 absent | Reject the handshake |
| `TIMESTAMP` present in a `RESPONSE` | Reject the handshake |
| `RESET_TOKEN` absent from a `RESPONSE`, or not 16 bytes | Reject the handshake |
| `MAX_DATAGRAM_SIZE` TLV disagrees with the `CONFIGURATION` value | Reject the handshake |
| Stream table empty, > 32 entries, contains id 0, or has a duplicate id | Reject the handshake |
| Stream table names an unassigned kind, direction or class | Reject the handshake |
| Unknown handshake TLV type | Skip by its length |
| `RESPONSE` larger than the `INIT` that triggered it | Sender MUST NOT send; receiver MUST reject |
| `SESSION_UNKNOWN` not exactly 21 bytes, wrong `session_id`, or bad token | Ignore |

### Chunks

| Condition | Action |
|---|---|
| Fewer than 3 bytes remain | Stop parsing, ignore the remainder |
| A chunk's `length` exceeds the bytes remaining | Stop parsing. Chunks already processed stand |
| Unknown chunk type | Skip by its length, continue |
| Chunk body malformed | Discard that chunk only, continue |
| Chunk names a stream not in the table | Discard, count |
| Chunk type does not match the stream's class | Discard, count |
| Chunk arrives against the stream's direction | Discard, count |

### Media fragments

| Condition | Action |
|---|---|
| `fragment_count == 0`, or `fragment_index >= fragment_count` | Discard |
| `stride == 0` | Discard |
| Payload empty, or longer than `stride` | Discard |
| Payload ≠ `stride` and not the last fragment | Discard |
| `fragment_count` or `stride` disagrees with an accepted fragment of the same frame | Discard |
| `fragment_count × stride` exceeds the frame size bound | Discard, **before** allocating |
| Unimplemented FEC scheme | Discard the fragment, continue the datagram |
| Names an already-completed `frame_id` | Discard silently |
| Duplicate of a fragment already placed | Discard, count |

### Frames and control

| Condition | Action |
|---|---|
| `ref_kind == LTR` but the header is too short for `ref_frame_id` | Discard the frame |
| `ext_len` exceeds the bytes available | Discard the frame |
| `IDR` without `CODEC_CONFIG` | Discard the frame, count |
| Unknown frame extension TLV | Skip by its length |
| Frame references a frame not delivered | Hold or discard per [video.md](video.md); MUST NOT deliver |
| `FEEDBACK` lengths do not exactly consume the chunk | Discard the chunk |
| `ack_count` exceeds the bound | Discard the chunk |
| `REFRESH_REQUEST` with unassigned `reason` or `preferred` | Discard the chunk |
| Reliable segment with `seg_count == 0` or `seg_index >= seg_count` | Discard |
| Reliable segment whose `seg_count` disagrees with an accepted one | Discard |
| Reliable message beyond the receive bound | Report an error, do not grow |
| Control message naming a stream not in the table | Discard |
| Control message whose TLVs do not exactly consume it | Discard |
| Unknown control message type | Discard, count |
| Unknown configuration TLV | Skip by its length |
| Unassigned `CLOSE` code | Close the session, treat as `NORMAL` |

## Security considerations

### What the protocol protects

Every packet after the handshake is encrypted and authenticated with AES-128-GCM. An
attacker who cannot read the pairing key cannot read media, inject packets, or modify
anything in flight without the tag failing.

The handshake authenticates both ends by their possession of the pairing key. Forward
secrecy comes from the ephemeral X25519 exchange: an attacker who later obtains the
pairing key cannot decrypt a recorded session, because the ephemeral private keys are
gone.

### What it does not protect

- **Traffic analysis.** Packet sizes and timing are visible, and video bitrate varies
  with content. An observer can tell a great deal about what is on screen without
  decrypting anything.
- **The pairing key's distribution.** How the two ends came to share a key is outside
  this protocol. A key exchanged over an insecure channel offers no security at all.
- **Denial of service by an on-path attacker**, who can simply drop packets.
- **Replay of a whole session** to a host that has forgotten it, if the attacker also
  holds the pairing key.

### Requirements

- The pre-shared key MUST be at least 32 bytes from a cryptographically secure random
  source. A key derived from a password, a device identifier, or anything with low
  entropy defeats the handshake entirely.
- The host secret used for reset tokens MUST be at least 32 bytes from the same kind of
  source, MUST be generated at startup, and MUST NOT be transmitted.
- Ephemeral X25519 keys MUST be fresh for every handshake and MUST NOT be reused across
  sessions.
- A packet number MUST NOT be reused under a given key. This is the one failure from
  which nothing can be recovered: two packets sealed with the same nonce and key expose
  the authentication key.
- Reset tokens MUST be compared in constant time.
- An implementation MUST NOT let an unauthenticated packet change any state — not the
  replay window, not the peer address, not the handshake replay cache.

### Amplification

A host MUST NOT send more bytes in response to an unauthenticated packet than it
received. Three rules enforce this:

- `INIT` is padded to `max_datagram_size`, and `RESPONSE` MUST be smaller.
- `SESSION_UNKNOWN` is sent only in response to a packet of at least 32 bytes, and is 21.
- `SESSION_UNKNOWN` is rate-limited host-wide.

An implementation that relaxes any of these turns the host into an amplifier for
source-address spoofing.

## Minimal implementation checklists

What must work for an implementation to interoperate. Everything listed is fully
specified in this directory.

### A conforming client

**Handshake**
- [ ] Generate a fresh X25519 ephemeral per handshake
- [ ] Build `INIT`, padded to `max_datagram_size`, with the required TLVs 1, 2, 3, 4, 5
- [ ] Derive the INIT-sealing key and seal the body with the 44-byte prefix as AAD
- [ ] Set don't-fragment on the socket
- [ ] Retransmit the **identical** `INIT` on backoff, up to 8 attempts
- [ ] Parse `RESPONSE`, derive the transcript, and derive all three key sets
- [ ] Adopt the `RESPONSE`'s stream table, not the one proposed
- [ ] Store the reset token

**Packets**
- [ ] Build and parse the 16-byte header; write reserved bytes zero
- [ ] Maintain a per-direction packet-number counter, incrementing on every datagram
- [ ] Reconstruct 64-bit packet numbers from 32-bit `transport_seq`
- [ ] Maintain a 2048-bit replay window, committing only after authentication
- [ ] Parse chunks with must-ignore, stopping safely on truncation, containing errors

**Receiving media**
- [ ] Place fragments at `fragment_index × stride` without depending on arrival order
- [ ] Validate every fragment per the table above, checking size bounds before allocating
- [ ] Parse the frame header, including the conditional `ref_frame_id`
- [ ] Extract `CODEC_CONFIG` from every `IDR` and build a decoder from it
- [ ] Deliver frames in `frame_id` order with a bounded hold queue
- [ ] Gate decodability per reference kind, never on a `REALTIME` stream
- [ ] Keep reassembly slots and a completed-`frame_id` set after delivery
- [ ] Report audio gaps rather than skipping them

**Feedback**
- [ ] Send `FEEDBACK` with an **MSB-first** bitmap and **chained** deltas
- [ ] Always write `ack_count`, even when zero
- [ ] `NACK` only holes below the highest index received, plus a tail timer
- [ ] Acknowledge long-term references only after a successful decode, rate-limited
- [ ] Send `REFRESH_REQUEST` on an expired frame, repeating with a stable `req_id` within each bounded attempt and a new identifier after expiry
- [ ] Reply to `PING` with `PONG` carrying the hold time

**Sending**
- [ ] Reliable messages on stream 0 and on input streams, `msg_seq` initially 0 and retained across ordinary resume
- [ ] Retransmit unacknowledged segments on a timeout
- [ ] Pace outbound media; never pace control chunks

**Lifecycle**
- [ ] Send `PING` every 250 ms when otherwise idle
- [ ] `PARK` when going idle; `RESUME` on a **new socket** with `decoder_lost` correct
- [ ] Repeat `RESUME` on backoff until `STATE` arrives
- [ ] Validate `SESSION_UNKNOWN` fully, with a constant-time token comparison
- [ ] Re-handshake on wake; never resume across system sleep

### A conforming host

Everything above that applies to receiving and sending, plus:

- [ ] Look up the pairing key by `pairing_id`; reject unknown ones
- [ ] Validate the `INIT`'s declared size against its actual length
- [ ] Validate the timestamp window
- [ ] Maintain the `INIT` replay cache and **resend the cached `RESPONSE`** on a duplicate
- [ ] Clear `INTRA_REFRESH` and `FEC` from the accepted capabilities
- [ ] Ensure `RESPONSE` is no larger than the `INIT`
- [ ] Assign a non-zero `session_id`; bound concurrent sessions
- [ ] Park on `PARK` or on 2 s of silence, releasing every media buffer
- [ ] Retain keys, counters, replay window, stream table, configuration and statistics
- [ ] Arm no timer for a parked session; expire by periodic sweep
- [ ] Bound and evict parked sessions, oldest first
- [ ] Signal idle at `pipeline_idle_after`; expire at `grace_window`, in running time
- [ ] Rebind only on an authenticated, in-window, strictly-newest packet
- [ ] On resume: rebind, flush media only, preserve reliable state, send `STATE{RESUME}`, produce an `IDR` per video stream
- [ ] Answer `REFRESH_REQUEST`, escalating `LTR_ANY` → `IDR` correctly
- [ ] Retain acknowledged references, bounded, discarding oldest first
- [ ] Apply `RECONFIGURE` partially and answer with the values actually applied
- [ ] Increment `CONFIG_GENERATION` only on a real change
- [ ] Force an `IDR` on a `RESOLUTION` or `HDR` change
- [ ] Engage the loss backstop; never raise the bitrate on its own
- [ ] Rate-limit `SESSION_UNKNOWN`

## Interoperability tests worth running

These are the cases where two implementations most often appear to work and do not.

1. **Lose the `RESPONSE`.** The client must retransmit the identical `INIT`; the host
   must answer from its cache; the session must establish.
2. **Cross-check the `FEEDBACK` bitmap.** Have one side report a known arrival pattern
   and assert the other derives exactly the same missing set. A bit-order mismatch
   produces no error.
3. **Cross-check chained deltas** over a report of several hundred packets, where an
   absolute encoding would clamp.
4. **Send a keyframe large enough to fragment into hundreds of pieces** and assert the
   receiver issues no `NACK` on a lossless link.
5. **Deliver the last fragment of a frame first**, then the rest out of order.
6. **Answer a `NACK` after the frame was already delivered** and assert the frame is not
   delivered twice.
7. **Break the `PREVIOUS` chain while retaining valid acknowledged long-term references**, then send `LTR_ANY`; assert delivery is allowed, and separately assert rejection after decoder reset until a new IDR decodes.
8. **Drop an audio frame** and assert the next is still delivered, and the gap reported.
9. **Change the client's source port mid-stream** without parking; assert the stream
   continues with no keyframe.
10. **Park, wait past the idle threshold, resume from a new port**; assert `STATE` arrives
    and the first frame delivered is an `IDR`.
11. **Return after the grace window**; assert `SESSION_UNKNOWN` and a clean re-handshake.
12. **Send an unknown chunk type, an unknown TLV and an unknown frame extension** in
    otherwise valid packets; assert all three are skipped and the surrounding data is
    processed.
13. **Send a malformed chunk after a valid one in the same datagram**; assert the valid
    one was processed.

## Regression scenarios from the HEVC demo

- [ ] Park with a missing reliable command, a later completed and acknowledged command, and pending outgoing messages; resume and deliver each exactly once in order with continued sequence numbers.
- [ ] Deliver an unseen pre-park reliable packet after resume and verify it fills its original gap without colliding with a new command.
- [ ] Lose a recovery frame beyond its repair deadline; expire the attempt and recover with a new request identifier.
- [ ] Restart the host with a new reset key; ignore the unverifiable reset and complete the bounded liveness fallback to a fresh handshake.
- [ ] Advance frame identifiers through `0xffffffff` to 1 and preserve `PREVIOUS` gating across the wrap.
- [ ] Change bitrate, frame rate and MTU without an IDR and preserve prediction across the generation boundary.
- [ ] Pace a large keyframe on a clean path without immediately NACKing its queued tail; expire genuinely late frames without unbounded buffering.
- [ ] Decode the published IDR example and authenticate the published protected datagram, asserting that its media fragment travels alone.
