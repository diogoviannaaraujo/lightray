# Video

> **Version 0 text, to be rewritten for version 1** once the Windows encoder measurements are
> in ([gaps.md](gaps.md)). Version 1 changes:
>
> - an HEVC contract: low-delay, with no B-frames and no reordering; Main, Main10, and optionally
>   4:4:4;
> - per-frame Reed–Solomon FEC (RFC 5510) as FEC scheme 1;
> - a reference epoch in the frame header, counting IDRs and decoder resets, so that both ends
>   agree on what the client's decoder holds;
> - recovery in the order FEC, retransmission when it can land within the latency budget, a
>   recovery frame the client requests, then an IDR. The host chooses how to make the recovery
>   frame, and the client declares whether its decoder accepts recovery frames that aren't IDRs;
> - tail loss detected from gaps in `transport_seq`, replacing the tail timer;
> - the `CAPABILITIES` parameter, and the fragment overhead that version 0's README gave;
> - several video streams in one session, one for each display the client shows, each
>   independent of the others ([displays.md](displays.md)).

Video travels on a stream of class `MEDIA`. A frame is submitted whole by the
application, split into fragments, and reassembled by the receiver into the same bytes.
The protocol never inspects the payload.

## Frames and frame identifiers

The sender assigns each frame a `frame_id`, a `u32` that increments by one per frame on
that stream. The first frame on a stream is `frame_id` **1**; the value **0** means "no
frame" and MUST NOT be assigned.

A `frame_id` is assigned **only to frames that produced bytes**.

> **Why not one identifier per capture.** An encoder under a tight latency budget may
> decide a frame is not worth sending and emit nothing for it. If identifiers were
> assigned per capture, that decision would leave a gap in the sequence that a receiver
> could not distinguish from a frame lost entirely — and the receiver would ask for the
> retransmission of something that was never sent. Assigning on output makes every gap a
> real loss. Capture cadence remains visible through `capture_time_us`.

`frame_id` wraps. Comparisons MUST use serial-number arithmetic: `a` is newer than `b`
when `a ≠ b` and `(a − b) mod 2³²` is less than 2³¹.

The successor of `0xffffffff` is **1**, and the predecessor of **1** is `0xffffffff`.
Implementations MUST skip zero when advancing frame identifiers or locating the `PREVIOUS` reference; serial comparisons retain the arithmetic above.

## The frame header

The sender logically prepends a header to the frame's bytes. Fragmentation then operates
on `header ‖ payload` as one byte string, so fragmentation never inspects the payload and
the header costs no separate datagram.

```
frame_type:u8
ref_kind:u8
flags:u8
config_generation:u32
capture_time_us:u32
ref_frame_id:u32          present only when ref_kind == LTR (2)
ext_len:u16               total length of the extension TLVs
ext TLVs[ext_len]         type:u8, length:u16, value
--- frame payload follows ---
```

Minimum 13 bytes; 17 when `ref_frame_id` is present.

| Field | Meaning |
|---|---|
| `frame_type` | `IDR`, `PREDICTED` or `AUDIO`. See [registries.md](registries.md). |
| `ref_kind` | What this frame references: nothing, the previous frame, a specific long-term reference, or any acknowledged one. |
| `flags` | Bit 0 `LTR_MARK`. Bit 1 is reserved for an intra-refresh-complete marker. |
| `config_generation` | The configuration generation this frame was produced under; see [control.md](control.md). |
| `capture_time_us` | When the source frame was captured, on the sender's monotonic clock. |
| `ref_frame_id` | The referenced frame, present only for `ref_kind = LTR`. |

A receiver MUST reject a frame whose `ref_kind` is `LTR` and which is too short to carry
`ref_frame_id`, and MUST reject one whose `ext_len` exceeds the bytes available.

A receiver MUST skip an extension TLV whose type it does not recognise.

### CODEC_CONFIG

Extension TLV type 1. **Every `IDR` MUST carry it**, and a receiver MUST reject an `IDR`
that does not.

Its value is the HEVC parameter sets — VPS, then SPS, then PPS — each encoded as a
4-byte big-endian length followed by that many bytes of NAL unit:

```
vps_len:u32  vps[vps_len]
sps_len:u32  sps[sps_len]
pps_len:u32  pps[pps_len]
```

The NAL units MUST NOT carry Annex B start codes, and MUST NOT have emulation-prevention
bytes removed — they are the NAL units as the encoder produced them, minus the start
code.

> **Why every IDR carries it, rather than a separate message once.** The parameter sets
> are not in-band in slice data, and no decoder can be constructed without them. They
> change only when resolution or profile changes, and both of those force an `IDR`
> anyway. Attaching them to the frame that needs them means a receiver joining at an
> `IDR`, or rebuilding a decoder after losing one, never has to wait for or correlate a
> separate message: the frame is self-sufficient. The cost is around 80 bytes per
> keyframe.

### Frame payload format

The payload is the access unit's NAL units, each preceded by a 4-byte big-endian length,
in decode order, with no start codes:

```
nal_len:u32  nal[nal_len]
nal_len:u32  nal[nal_len]
...
```

One `frame_id` carries exactly one access unit.

> **Why length-prefixed rather than Annex B.** The transport already knows exactly how
> many bytes a frame is, so start-code scanning buys nothing, and a length prefix cannot
> be confused by payload bytes that happen to look like a start code.

### Worked examples

A complete, decodable 16 × 16 HEVC `IDR` with an 80-byte `CODEC_CONFIG`, generated using libx265:

```
000001000000030001e24000530100500000001840010c01ffff01600000030090000003000003003cba02400000002642010101600000030090000003000003003ca0884596e96f0b9a020000030002000003003c10000000064401c0718112000001432801ac1ae0f33d5fdcfddf03600717810da9f57f7bb115b7924631e1020000cacc5d6c1c47cdb924cb879dd8cd3e9efad4eb38f5abc256ca0d205c7abc3897c1456af493a979ed56e5d4411b5d6d972bad41ed61679250c54bd927454a389f0ce54ba83c5be0ba8b8ff2ea1e0aa497e49ec2fa2d3d272d6e188d578c2f27e6f449751f96f27ff5ae8352f2988bf52c1aa503dce248121b4042e5b3faf9c3adf9fe7ee3c06bfe1199fa8b9dbfd30090fed9f9eeee3be33dc398516216bdafea5bbbeaac3ec37adc7fa611e4a3b589aee7e0fbe17cadea66770a486e9ae25821bd4b8925e02d311d842c4ffda14eb6c4f1b1598211604264759329ef4c1e7fb35f201bdfb25e12f9b0778d61e5eb242bf2202706106410a5ad36084f2cf64b27a9a039ed2f3c5c784c2129387bf43ee726767425c27a3a514fde71cef2456b108e7a27c0
```

The frame is 423 bytes: a 13-byte fixed header, an 83-byte extension area, and a 327-byte length-prefixed IDR payload.
The header has `frame_type = IDR`, `ref_kind = NONE`, `flags = LTR_MARK`, generation 3, and capture time 123456.
The extension is TLV type 1, length 80, containing VPS, SPS and PPS of 24, 38 and 6 bytes respectively, each preceded by its own `u32` length.

A predicted frame header referencing a specific long-term reference (payload omitted):

```
0102000000000100000005000010920000
```

`frame_type` 1, `ref_kind` 2 (`LTR`), `flags` 0, generation 1, capture 5, `ref_frame_id` 4242, `ext_len` 0.

The same header with `ref_kind = LTR_ANY` carries no `ref_frame_id` and is **four bytes shorter** (13 bytes instead of 17):

```
01030000000001000000050000
```

## Fragmentation

The byte string `header ‖ payload` is divided into fragments of exactly `stride` bytes,
except the last, which carries the remainder.

```
stride = max_datagram_size − 51
```

The 51 bytes are the fixed overhead: the 16-byte protected header, the 3-byte chunk header,
the 13-byte fragment header, the 3-byte FEC extension TLV and the 16-byte authentication tag.
At the default 1200-byte datagram, `stride` is 1149.

Fragment `i` carries bytes `[i × stride, (i+1) × stride)`. A receiver places any fragment
at `fragment_index × stride` in a contiguous buffer, the moment it arrives, with no
dependence on any other fragment.

> **Why the stride is on the wire.** It makes placement unconditional. A receiver can
> place the last fragment of a frame before it has seen any other, and can place a
> retransmission of a fragment that was sent under a different `max_datagram_size`. The
> alternative — inferring the stride from the first fragment seen — fails in both of
> those cases, and both happen routinely.

A frame is complete when all `fragment_count` fragments have arrived. Its length is
`(fragment_count − 1) × stride` plus the last fragment's payload length.

## MEDIA_FRAGMENT (`0x01`)

```
stream:u8
flags:u8
frame_id:u32
fragment_index:u16
fragment_count:u16
stride:u16
ext_len:u8                total length of the extension TLVs
ext TLVs[ext_len]         type:u8, length:u8, value
payload[...]              the remainder of the chunk
```

13 fixed bytes, then the extension TLVs, then payload.

Note that a fragment's extension TLVs use a **one-byte** length, unlike every other TLV
in the protocol. The space is tight and these TLVs are small by construction.

Version 0 always writes exactly one extension TLV, the FEC scheme:

```
01 01 00        type 1, length 1, scheme NONE
```

A receiver MUST discard a fragment naming a FEC scheme it does not implement, and MUST
continue processing the rest of the datagram.

### Validation

A receiver MUST discard a fragment unless all of the following hold:

- `fragment_count > 0`
- `fragment_index < fragment_count`
- `stride > 0`
- the payload is non-empty and no longer than `stride`
- the payload is **exactly** `stride` bytes unless `fragment_index == fragment_count − 1`

A receiver MUST also discard a fragment whose `fragment_count` or `stride` disagrees
with a fragment of the same `frame_id` it has already accepted.

A receiver MUST bound the memory a single frame may occupy and MUST check that bound
against `fragment_count × stride` **before** allocating.

### Worked example

```
01001801010000000700040005047d03010100a0a1a2a3a4a5a6a7
```

| Bytes | Value | Field |
|---|---|---|
| `01` | `0x01` | type, `MEDIA_FRAGMENT` |
| `0018` | 24 | length |
| `01` | 1 | `stream` |
| `01` | bit 0 | `flags`: `KEYFRAME` |
| `00000007` | 7 | `frame_id` |
| `0004` | 4 | `fragment_index` (last fragment) |
| `0005` | 5 | `fragment_count` |
| `047d` | 1149 | `stride` |
| `03` | 3 | `ext_len` |
| `010100` | | FEC TLV, scheme `NONE` |
| `a0a1…a7` | 8 bytes | payload |

## Retransmission

A sender MUST retain frames it has sent so that it can answer a `NACK`. It SHOULD retain
them for at least 500 ms and MAY bound the store by bytes; 16 MB is RECOMMENDED.

A retransmitted fragment MUST set `RETRANSMISSION` in its flags, MUST carry the stride it
was originally sent with, and MUST be given a **new** `transport_seq`.

A sender SHOULD NOT retransmit the same fragment twice within half a round-trip time,
and MUST NOT retransmit a fragment of a frame whose deadline has passed.

A sender MUST send retransmissions ahead of new media data. A `NACK`ed fragment is
already late.

### Deadline origins

The sender's frame deadline starts when the encoded frame is submitted to the transport, before pacing.
The receiver's deadline starts at the first fragment's arrival, or at gap discovery when an entire frame is missing.
Each endpoint MUST snapshot the frame interval when starting its local deadline; a later frame-rate change MUST NOT retroactively move that deadline.
The default lifetime is three frame intervals, measured with the endpoint's own monotonic clock.

## Reassembly

A receiver MUST keep a frame's reassembly slot after the frame has been delivered, until
it is evicted by age or capacity.

> **Why keep it.** A `NACK` sent just before the last missing fragment arrived will be
> answered shortly after the frame was delivered. If the slot is gone, that
> retransmission looks like the first fragment of a brand-new frame, and the frame is
> reassembled and delivered a second time. Keeping the slot lets the receiver recognise
> the arrival as redundant and drop it.

A receiver MUST also keep a bounded record of recently completed `frame_id`s per stream —
at least 256 — and MUST silently discard fragments naming one of them.

## Delivery order

Frames MUST be delivered to the application in increasing `frame_id` order.

A frame that completes while an earlier frame on the same stream is still being repaired
MUST be held, not discarded, until the earlier frame is delivered or given up on. A
receiver MUST bound this hold queue and MUST report an error rather than grow without
limit.

> **Why hold rather than discard.** A small predicted frame often completes before a
> large keyframe queued ahead of it, simply because it is smaller. Discarding it because
> its predecessor has not arrived throws away a frame that was about to be perfectly
> usable — and does so precisely when the link is already in trouble.

## Decodability

A receiver MUST NOT hand the application a frame whose references are missing.

> **Why the protocol has to gate this rather than leaving it to the decoder.** A decoder
> given a frame with missing references does not reliably report an error. It commonly
> returns success and produces visible corruption that then propagates through every
> frame that references it. By the time anything notices, the damage is several frames
> old.

The gate is evaluated **per reference kind**:

| `ref_kind` | Deliverable when |
|---|---|
| `NONE` | always |
| `PREVIOUS` | the immediately preceding frame on this stream was delivered |
| `LTR` | the named frame was acknowledged as decoded and remains a valid decoder reference |
| `LTR_ANY` | the sender’s eligible acknowledged reference set remains valid in the receiver’s decoder |

A gap in the `PREVIOUS` chain alone MUST NOT prevent delivery of an `LTR_ANY` whose reference-validity gate is satisfied, or an `IDR`.

A decoder reset invalidates previous reference acknowledgements; the receiver MUST reject predicted frames until it has successfully decoded a new `IDR`.
A `PREVIOUS` gap alone does not invalidate retained long-term references.
Historical acknowledgement alone is insufficient to establish current reference validity.
Version 0 still lacks a complete reference-lifetime and stale-acknowledgement contract; see [gaps.md](gaps.md).
Implementations unable to establish this validity MUST use IDR-only recovery without negotiating `LTR`.

Decodability gating MUST NOT be applied to a stream of class `REALTIME`. See
[audio.md](audio.md).

An implementation MAY offer a mode that refuses every long-term reference and recovers
only by `IDR`, for use with encoders that do not support them.

## Long-term references

When the `LTR` capability is negotiated, the sender marks frames it is willing to use as
long-term references by setting `LTR_MARK`. A sender SHOULD mark every frame.

The **receiver** chooses which of those become reference points. Having decoded a
marked frame, a receiver MAY acknowledge it with `FRAME_ACK` and status `DECODED`. A
receiver SHOULD acknowledge at most one frame per 250 ms.

A receiver MUST NOT acknowledge a frame it has not decoded successfully. Delivery is not
decoding; an implementation that acknowledges on delivery has broken the guarantee that
makes `LTR_ANY` safe.

A sender MUST retain the most recent acknowledgements and MUST bound the set; 16 is
RECOMMENDED. It MUST discard older acknowledgements first.

> **Why the receiver picks and the interval is coarse.** The sender cannot know what
> decoded successfully, so the acknowledgement has to originate at the receiver. Rate
> limiting it to a few per second, rather than one per frame, keeps the acknowledged set
> and the feedback volume proportional to time rather than to frame rate, which matters
> at 120 fps and costs nothing at 30.

## Recovery

Recovery escalates. Each step is tried only when the one before it cannot succeed in
time.

### 1. Retransmission

A receiver detects missing fragments and asks for them by `NACK`; see
[feedback.md](feedback.md). This is the only step that costs nothing visible.

### 2. A frame that repairs the reference chain

When a frame cannot be completed by its deadline and the decoder is still alive, the
receiver sends `REFRESH_REQUEST` with reason `LOSS`. It sets `preferred` to `LTR` if the
`LTR` capability was negotiated and it has acknowledged at least one frame, otherwise to
`IDR`.

On receiving a request with `preferred = LTR` and holding at least one acknowledgement,
the sender asks its encoder for a frame referencing **any** of its retained acknowledged
references, and marks the result `ref_kind = LTR_ANY`. Otherwise it produces an `IDR`.

> **Why `LTR_ANY` rather than naming the reference.** Hardware encoders in common use do
> not let the caller choose which long-term reference a frame will use; they accept a set
> of candidates and choose internally, without reporting the choice. Naming the reference
> on the wire would require information the sender cannot obtain. `LTR_ANY` says "one of
> the frames you told me you decoded", which is exactly what the sender knows and exactly
> what the receiver must still establish under the reference-lifetime contract.

### 3. A keyframe

If `LTR` was not negotiated, if no acknowledgement exists, or if the receiver's decoder
was lost, the answer is an `IDR` with its own `CODEC_CONFIG`.

A receiver whose decoder is lost or rebuilt MUST send `REFRESH_REQUEST` with reason
`DECODER_RESET` and `preferred = IDR`, and MUST discard every acknowledgement it has
issued.

### Repeating the request

A recovery attempt begins with the first transmission of a `REFRESH_REQUEST`.
The requester MUST reuse its `req_id` within that attempt and SHOULD repeat no more often than once per round-trip time.
The media sender MUST produce at most one recovery frame per `req_id` on that stream; duplicate requests do not create additional frames.
An attempt succeeds only when a suitable recovery frame is successfully decoded; `DECODER_RESET` requires an `IDR`.
The requester MUST bound the attempt lifetime, measured from its first transmission; `max(2 × frame_deadline, 3 × srtt)` is RECOMMENDED, with those values sampled at attempt start.
If recovery has not succeeded by expiry, it MUST begin a new attempt with a new `req_id`, allowing the sender to produce a replacement recovery frame.
Request identifiers increment modulo 2³² per stream and MUST NOT be reused while an earlier attempt with that identifier can remain outstanding.
Ordinary resume preserves this identifier sequence.
The sender MUST bound duplicate-request bookkeeping and retain it for at least the supported attempt lifetime.
A fresh attempt MUST NOT be ignored solely because `lost_frame` precedes a recovery frame already produced: that recovery frame may itself have been lost.

## Pacing

A sender MUST NOT transmit a frame's fragments as fast as the socket will accept them.

> **Why this is a requirement.** A keyframe at a high resolution can be several hundred
> kilobytes — hundreds of datagrams. Released at line rate, that burst arrives at the
> first bottleneck as a single event, fills its queue, and is partly discarded. The loss
> is then repaired by retransmissions that arrive in another burst. The frame that caused
> it is the keyframe, so the failure concentrates exactly where recovery is least
> affordable. Encoders commonly ignore per-frame size limits, so the transport is the
> only place this can be bounded.

A sender MUST enforce a configured byte-rate envelope with bounded bursts; it need not stretch every small frame to a full frame interval.
The following token-bucket policy is RECOMMENDED:

- Refill in bytes per second at `max(1.25 × bitrate / 8, queued_frame_bytes / frame_interval)`, subject to a configured pacing-rate cap.
- Account for complete protected datagram bytes, including retransmissions, in the bucket and backlog.
- Limit the burst to 32 datagrams.
- Prioritize control chunks, then retransmissions, then `REALTIME` streams, then `MEDIA` streams.

Here `bitrate` is in bits per second and `frame_interval` is in seconds.
If the configured cap prevents timely delivery, the sender MUST expire late media rather than grow an unbounded backlog.

The rate MUST follow the whole backlog, not the newest frame alone.

> **Why the whole backlog.** Setting the rate from the size of the frame just submitted
> lets a small frame queued behind a large keyframe lower the rate while the keyframe is
> still draining, stranding it past its deadline.

Control chunks MUST NOT be delayed by pacing. A `NACK` or a `RESUME` held behind an empty
token bucket defeats its own purpose.

### Experimental host timing extension (local Windows laboratory)

The Windows laboratory implementation optionally emits type `0xF0`, a provisional local TLV that must be coordinated before becoming a protocol assignment.
Its 17-byte value contains `version:u8 = 1`, `capture_duration_us:u32`, `encode_duration_us:u32`, and `host_sample_id:u64`, with all integers big-endian.
The extension adds 20 bytes per frame, including the TLV header, and is omitted when it would exceed the extension area's `u16` length budget.
The durations use the host's monotonic clock and are each limited to 1,000,000 microseconds; no clock synchronization is assumed.
The sample ID is the native host's frame-attempt counter for its current process and can contain gaps; it is diagnostic and is not a protocol frame ID or a globally unique identifier.
Frame association, stream identity and session lifetime come from the enclosing video frame and transport.
Unknown versions, invalid value sizes, out-of-range durations and duplicate timing TLVs make the optional timing unavailable without invalidating otherwise valid video; malformed TLV framing still invalidates the frame.
Receivers without this extension continue to skip it according to the existing unknown-extension rule.
Absence of the extension means unavailable, never zero.

In the native Windows host, capture/convert measures the wall time of desktop acquisition and conversion submission; encode measures the synchronous encoder call through output availability.
GPU work is asynchronous, so waits for previously submitted conversion can appear inside encode; these are application stage boundaries, not isolated GPU execution timers.
Cached desktop frames remain timing samples, and decoded FPS must not be interpreted as new desktop updates or display presentations.
The Mac HUD averages host samples from successful current-epoch decodes over the reporting interval (approximately one second), independently from client decode and queue durations.
The samples exclude lost, undecodable and dropped frames, so they are not an unbiased measure of every host attempt.
RTT remains round-trip network time; summing these values does not produce input-to-photon latency.
