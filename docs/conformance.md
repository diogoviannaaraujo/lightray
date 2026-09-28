# Conformance

A section marked *Version 0, pending* is carried unchanged from version 0 until the documents
it covers are rewritten for version 1.

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
| Handshake packet whose version is not 1 | Discard, count. MUST NOT reply |
| Protected packet shorter than 32 bytes | Discard, count. MUST NOT reply |
| `session_id` names no session, packet ≥ 32 bytes | Discard. Send `SESSION_UNKNOWN`, subject to rate limiting |
| Authentication fails | Discard, count. MUST NOT change any state |
| Packet number already seen, or more than 2047 behind | Discard, count |
| Authenticated packet from a new address, not strictly newest | Discard, count. MUST NOT rebind |
| Rebind to a new IP address, not yet validated | Send at most 3 × the bytes received from it |
| Protected packet reaching a client before its `RESPONSE` | Hold up to 64; open them once the keys exist. MUST NOT change any state before then |

### Handshake

| Condition | Action |
|---|---|
| `INIT` outside 256–9000 bytes | Discard, count, before opening it |
| `INIT` names an unknown `pairing_id` | Discard, count |
| `INIT` fails to open | Discard, count |
| `INIT` digest already in the replay cache | **Resend the cached `RESPONSE`**, whatever its timestamp now says. MUST NOT create or take over a session |
| `INIT` length ≠ its declared `MAX_DATAGRAM_SIZE` | Discard, count |
| `INIT` timestamp more than 30 s from the host's clock | Discard, count |
| `INIT` whose ephemeral makes `DH` fail or produce zeros | Discard, count. MUST NOT reply |
| `params_len` exceeds the payload | Discard, count |
| A TLV of type 1–7 appears twice | Reject the handshake |
| A TLV required in that packet is absent, or one that MUST NOT appear is present | Reject the handshake |
| A TLV's length is wrong for its type | Reject the handshake |
| A TLV's length exceeds the bytes remaining in `params`, or one or two bytes remain after the last TLV | Reject the handshake |
| Stream table empty, > 32 entries, contains id 0, or has a duplicate id | Reject the handshake |
| Stream table names an unassigned kind, direction or class | Reject the handshake |
| Unknown handshake TLV type | Skip by its length |
| `RESPONSE` type or version other than `0x81` and 1 | Discard |
| `RESPONSE` larger than the client's `INIT` | Sender MUST NOT send; a client discards it without opening it, and keeps waiting |
| `RESPONSE` fails to open, or its ephemeral makes `DH` fail or produce zeros | Discard; keep waiting. The client's state MUST be as it was before |
| `RESPONSE` payload shorter than 20 bytes | Reject the handshake |
| `RESPONSE` with `session_id` 0 | Reject the handshake |
| `RESPONSE` stream table adds a stream or changes an entry | Reject the handshake |
| `RESPONSE` `MAX_DATAGRAM_SIZE` above the client's | Reject the handshake |
| `RESPONSE` after the client's handshake completed | Ignore |
| `SESSION_UNKNOWN` not exactly 22 bytes, wrong version, wrong `session_id`, or bad token | Ignore |

A host rejects a handshake by discarding the `INIT` without replying. A client rejects one by
abandoning it and reporting the error to its application.

### Chunks

| Condition | Action |
|---|---|
| Fewer than 3 bytes remain | Stop parsing, ignore the remainder |
| A chunk's `length` exceeds the bytes remaining | Stop parsing. Chunks already processed stand |
| Unknown chunk type | Skip by its length, continue |
| `PADDING` | Ignore |
| Chunk body malformed | Discard that chunk only, continue |
| Chunk names a stream not in the table | Discard, count |
| Data chunk that does not belong to the stream's class | Discard, count |
| Data chunk against the stream's direction, or feedback chunk along it | Discard, count |
| `CLOSE` body shorter than 2 bytes | Discard the chunk |
| `CLOSE` body longer than 2 bytes | Read the code, ignore the rest |
| `CLOSE` with an unassigned code | Close the session, treat as `NORMAL` |

### Media fragments

*Version 0, pending [video.md](video.md).*

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

*Version 0, pending [video.md](video.md), [feedback.md](feedback.md), [control.md](control.md)
and [input.md](input.md).*

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

## Security considerations

### What the protocol protects

Every packet after the handshake is encrypted and authenticated with AES-256-GCM under keys
that belong to that session and direction. An attacker who does not hold the pairing key
cannot read media, inject packets, or modify anything in flight without the tag failing.

The handshake is Noise's `NNpsk0`. It authenticates both ends by their possession of the
pairing key, and the ephemeral–ephemeral Diffie–Hellman gives forward secrecy: an attacker
who later obtains the pairing key cannot read a recorded session's `RESPONSE` or traffic,
because the ephemeral private keys are gone.

The `INIT` is weaker, by construction. Its payload is sealed under a key derived from the
pairing key and a public value, so it has **no forward secrecy**, and anyone who later learns
the pairing key can read recorded `INIT`s. It can also be **replayed**, because nothing in it
comes from the host. Hence the rules that follow from it: an `INIT` MUST NOT carry anything
secret, and the timestamp window and the `INIT` cache ([handshake.md](handshake.md#replay-protection))
make a replay harmless.

### What it does not protect

- **Traffic analysis.** Packet sizes and timing are visible, and video bitrate varies
  with content. An observer can tell a great deal about what is on screen without
  decrypting anything.
- **The pairing key's distribution.** How the two ends came to share a key is outside
  this protocol. A key exchanged over an insecure channel offers no security at all.
- **Denial of service by an on-path attacker**, who can simply drop packets.
- **A holder of the pairing key.** Anyone with it can do anything the client can, including
  taking over the client's sessions.

### Requirements

- The pre-shared key MUST be exactly 32 bytes from a cryptographically secure random source.
  A key derived from a password, a device identifier, or anything with low entropy defeats
  the handshake entirely.
- The host secret used for reset tokens MUST be at least 32 bytes from the same kind of
  source, MUST be generated at startup, and MUST NOT be transmitted.
- Ephemeral X25519 keys MUST be fresh for every handshake and MUST NOT be reused across
  sessions. A retransmitted `INIT` is the same handshake, and repeats the same bytes.
- Each side MUST erase its ephemeral private key and handshake state once it has derived the
  traffic keys. Forward secrecy depends on it.
- A packet number MUST NOT be reused under a given key. This is the one failure from
  which nothing can be recovered: two packets sealed with the same nonce and key expose
  the authentication key. For the same reason a sender MUST close a session before its
  packet number reaches 2⁶⁴ − 1, the nonce Noise reserves.
- Reset tokens MUST be compared in constant time.
- An implementation MUST NOT let an unauthenticated packet change any state: not the
  replay window, not the peer address, not the handshake replay cache.

Section 14 of the Noise specification advises against encrypting more than 2⁵⁶ bytes under
one AES-GCM key. At a gigabit a second that is more than 18 years of one session, so no session
reaches it, and version 1 does not rekey ([gaps.md](gaps.md)).

### Amplification

A host MUST NOT send more bytes in response to an unauthenticated packet than it
received, nor stream to an address it has not validated. Four rules enforce this:

- `INIT` is padded to `max_datagram_size`, and `RESPONSE` MUST be no larger.
- `SESSION_UNKNOWN` is sent only in response to a packet of at least 32 bytes, and is 22.
- `SESSION_UNKNOWN` is rate-limited host-wide.
- After a rebind to a new IP address, an endpoint sends at most three times what it has
  received from that address until the address is validated ([packets.md](packets.md#validating-a-new-address)).

An implementation that relaxes any of these turns the host into an amplifier for
source-address spoofing.

## Minimal implementation checklists

What must work for an implementation to interoperate. The handshake and packet items are
version 1; the rest are *Version 0, pending* their documents.

### A conforming client

**Handshake**
- [ ] Generate a fresh X25519 ephemeral per handshake
- [ ] Run `NNpsk0` with the prologue `"lightray-v1" ‖ INIT[0..12)`
- [ ] Build `INIT`, padded to `max_datagram_size`, with `TIMESTAMP`, `STREAM_TABLE` and `MAX_DATAGRAM_SIZE`
- [ ] Set don't-fragment on the socket
- [ ] Retransmit the **identical** `INIT` on backoff, up to 8 attempts
- [ ] Open each `RESPONSE` on a copy of the state the `INIT` left, so that a bad one changes nothing
- [ ] Open `RESPONSE`, read `session_id` and `reset_token`, and split the traffic keys
- [ ] Adopt the `RESPONSE`'s stream table, rejecting one that adds or changes a stream
- [ ] Hold protected packets that arrive before the `RESPONSE`, up to 64
- [ ] Erase the ephemeral private key and handshake state after splitting

**Packets**
- [ ] Build and parse the 16-byte header; write reserved bytes zero
- [ ] Seal with AES-256-GCM, the direction's key, and the nonce `0x00000000 ‖ packet_number`
- [ ] Maintain a per-direction packet-number counter, incrementing on every datagram
- [ ] Never build a datagram larger than `max_datagram_size`
- [ ] Take `send_time_us` from a monotonic microsecond clock, and compare times with wrapping 32-bit arithmetic
- [ ] Reconstruct 64-bit packet numbers from 32-bit `transport_seq`
- [ ] Maintain a 2048-bit replay window, committing only after authentication
- [ ] Parse chunks with must-ignore, stopping safely on truncation, containing errors
- [ ] Discard chunks for unknown streams, the wrong direction for their role, or the wrong class

**Receiving media** *(version 0, pending)*
- [ ] Place fragments at `fragment_index × stride` without depending on arrival order
- [ ] Validate every fragment per the table above, checking size bounds before allocating
- [ ] Parse the frame header, including the conditional `ref_frame_id`
- [ ] Extract `CODEC_CONFIG` from every `IDR` and build a decoder from it
- [ ] Deliver frames in `frame_id` order with a bounded hold queue
- [ ] Gate decodability per reference kind, never on a `REALTIME` stream
- [ ] Keep reassembly slots and a completed-`frame_id` set after delivery
- [ ] Report audio gaps rather than skipping them

**Feedback** *(version 0, pending)*
- [ ] Send `FEEDBACK` with an **MSB-first** bitmap and **chained** deltas
- [ ] Always write `ack_count`, even when zero
- [ ] `NACK` only holes below the highest index received, plus a tail timer
- [ ] Acknowledge long-term references only after a successful decode, rate-limited
- [ ] Send `REFRESH_REQUEST` on an expired frame, repeating with a stable `req_id` within each bounded attempt and a new identifier after expiry
- [ ] Reply to `PING` with `PONG` carrying the hold time

**Sending** *(version 0, pending)*
- [ ] Reliable messages on stream 0 and on input streams, `msg_seq` initially 0 and retained across ordinary resume, except input the client clears
- [ ] Retransmit unacknowledged segments on a timeout
- [ ] Pace outbound media; never pace control chunks
- [ ] One input stream per device; merge waiting motion and gamepad state, ending the merge on a button change
- [ ] Touch and pen hover and move, and sensors, on an `UNRELIABLE` stream; pen button changes and a stopping gyroscope reliably

**Lifecycle**
- [ ] Validate `SESSION_UNKNOWN` fully, with a constant-time token comparison
- [ ] Name the old session in `RESUME_SESSION_ID` when reconnecting after a relaunch
- [ ] *(Version 0, pending)* Send `PING` every 250 ms when otherwise idle
- [ ] *(Version 0, pending)* `PARK` when going idle; `RESUME` on a **new socket** with `decoder_lost` correct
- [ ] *(Version 0, pending)* Before the first `RESUME`, discard unacknowledged input and fix each input stream's resume point
- [ ] *(Version 0, pending)* Name every reliable input stream's resume point in `RESUME`, unchanged across repeats
- [ ] *(Version 0, pending)* Repeat `RESUME` on backoff until `STATE` arrives
- [ ] *(Version 0, pending)* Re-handshake on wake; never resume across system sleep

### A conforming host

Everything above that applies to receiving and sending, plus:

**Handshake and packets**
- [ ] Look up the pairing key by `pairing_id`; reject unknown ones
- [ ] Open the `INIT` before any Diffie–Hellman, and validate its declared size against its length
- [ ] Validate the timestamp window
- [ ] Maintain the `INIT` replay cache and **resend the cached `RESPONSE`** on a duplicate
- [ ] Ensure `RESPONSE` is no larger than the `INIT`
- [ ] Assign a non-zero `session_id`; bound concurrent sessions
- [ ] Never add a stream to, or change an entry of, the proposed stream table
- [ ] Take over an active or parked session named in `RESUME_SESSION_ID`, or allocate a new one
- [ ] Erase the ephemeral private key and handshake state after splitting
- [ ] Rebind only on an authenticated, in-window, strictly-newest packet
- [ ] Cap what is sent to a new IP address at 3 × what it sent, until a `FEEDBACK` validates it
- [ ] Reset rate control after a rebind to a new IP address, but not after a change of port alone
- [ ] Rate-limit `SESSION_UNKNOWN`

**Everything else** *(version 0, pending)*
- [ ] Park on `PARK` or on 2 s of silence, releasing every media buffer and performing the input reset
- [ ] Retain keys, counters, replay window, stream table, configuration and statistics
- [ ] Arm no timer for a parked session; expire by periodic sweep
- [ ] Bound and evict parked sessions, oldest first
- [ ] Signal idle at `pipeline_idle_after`; expire at `grace_window`, in running time
- [ ] On resume: rebind, flush media only, preserve reliable state, send `STATE{RESUME}`, produce an `IDR` per video stream
- [ ] Apply resume points from every `RESUME`, forward only, discarding held and late input below them
- [ ] Input reset on park, session end and adoption, and per stream when a resume point moves it forward; ignore a release of anything not held
- [ ] Answer `REFRESH_REQUEST`, escalating `LTR_ANY` → `IDR` correctly
- [ ] Retain acknowledged references, bounded, discarding oldest first
- [ ] Apply `RECONFIGURE` partially and answer with the values actually applied
- [ ] Increment `CONFIG_GENERATION` only on a real change
- [ ] Force an `IDR` on a `RESOLUTION` or `HDR` change
- [ ] Engage the loss backstop; never raise the bitrate on its own

## Interoperability tests worth running

These are the cases where two implementations most often appear to work and do not. Tests 1,
9, 12, 13 and 18–26 cover version 1 text; the others are *Version 0, pending* their documents.

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
   continues with no keyframe and no cap on what the host sends.
10. **Park, wait past the idle threshold, resume from a new port**; assert `STATE` arrives
    and the first frame delivered is an `IDR`.
11. **Return after the grace window**; assert `SESSION_UNKNOWN` and a clean re-handshake.
12. **Send an unknown chunk type, an unknown TLV and an unknown frame extension** in
    otherwise valid packets; assert all three are skipped and the surrounding data is
    processed.
13. **Send a malformed chunk after a valid one in the same datagram**; assert the valid
    one was processed.
14. **Park with a key press delivered and its release unacknowledged**, then resume;
    assert the host released the key, did not wait for the cleared release, and
    delivers the next key event at once.
15. **Deliver a pre-park input message after the host has applied the resume point**;
    assert it is acknowledged and not delivered.
16. **Repeat a `RESUME` after newer input has been delivered**; assert nothing is
    skipped and nothing is released.
17. **Move a gamepad stick and press a button within one merge interval**; assert the
    host receives the stick position the client had at the press.
18. **Reproduce the worked examples.** Build the `INIT` and `RESPONSE` in
    [handshake.md](handshake.md#worked-example) from their inputs, and open the datagram in
    [packets.md](packets.md#a-complete-protected-datagram); the values are also in
    `tools/vectors/vectors.json`.
19. **Flip one bit of an `INIT`'s reserved bytes or pairing identifier**; assert the host
    cannot open it.
20. **Change the client's IP address mid-stream**; assert the host sends at most three times
    what it received from the new address until a `FEEDBACK` from there reports a packet sent
    there, then continues without a keyframe.
21. **Deliver the host's first protected packets ahead of its `RESPONSE`**; assert the client
    opens them once it has the keys.
22. **Kill the client and reconnect with `RESUME_SESSION_ID`** while the host still holds the
    session as active; assert the host takes it over and the old keys stop working.
23. **Stream two displays and lose a keyframe on one**; assert the other stream keeps
    delivering frames and receives no keyframe ([displays.md](displays.md#each-stream-is-independent)).
24. **Move one of two streams to another display**; assert an IDR in a new `config_generation`
    on that stream and nothing on the other.
25. **Remove a display the client is showing**; assert a new `DISPLAYS` arrives, the stream that
    showed it is reported unbound, and the other streams carry on.
26. **Bind more streams than the host's encoder can run**; assert the binding it cannot start is
    refused and the streams already running carry on.

## Regression scenarios

*Version 0, pending the documents they exercise.*

- [ ] On stream 0, park with a missing reliable command, a later completed and acknowledged command, and pending outgoing messages; resume and deliver each exactly once in order with continued sequence numbers.
- [ ] On stream 0, deliver an unseen pre-park reliable packet after resume and verify it fills its original gap without colliding with a new command.
- [ ] Lose a recovery frame beyond its repair deadline; expire the attempt and recover with a new request identifier.
- [ ] Restart the host with a new reset key; ignore the unverifiable reset and complete the bounded liveness fallback to a fresh handshake.
- [ ] Advance frame identifiers through `0xffffffff` to 1 and preserve `PREVIOUS` gating across the wrap.
- [ ] Change bitrate, frame rate and MTU without an IDR and preserve prediction across the generation boundary.
- [ ] Pace a large keyframe on a clean path without immediately NACKing its queued tail; expire genuinely late frames without unbounded buffering.
- [ ] Decode the published IDR example in [video.md](video.md).
