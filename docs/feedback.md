# Feedback, loss reporting and repair

> **Version 0 text, to be rewritten for version 1** ([gaps.md](gaps.md)), except for the
> decoded-only `FRAME_ACK` amendment below. Remaining version 1 changes:
>
> - `FRAME_ACK` carries the reference epoch;
> - `REFRESH_REQUEST` reports the last frame the client decoded, and its epoch;
> - an optional `RECEIVER_STATS` chunk for client overlays;
> - `FEEDBACK` from a new address validates it ([packets.md](packets.md#validating-a-new-address));
> - the loss backstop and the manually set bitrate give way to
>   [rate-control.md](rate-control.md).

Four chunks carry everything a sender learns about the path and about what the receiver
needs: `FEEDBACK` reports what arrived and when, `NACK` asks for fragments back,
`FRAME_ACK` establishes reference points, and `REFRESH_REQUEST` asks for a frame that
repairs the reference chain. `PING` and `PONG` keep an idle link warm.

## FEEDBACK (`0x10`)

The primary report. A receiver sends it periodically, describing a run of
`transport_seq` values: which arrived, when each arrived relative to the one before, and
which reliable messages are now complete.

```
base_seq:u32
count:u16
base_arrival_us:u32
bitmap[ceil(count / 8)]
deltas[popcount(bitmap)]      i16 each
ack_count:u16
acks[ack_count]               stream:u8, msg_seq:u32
```

`base_seq` is the lowest `transport_seq` this report covers; `count` is how many
consecutive values it covers. Bit *i* of the bitmap refers to `base_seq + i`.

### The bitmap is MSB-first

**Within each byte, bit *i* of the report is bit `7 − (i mod 8)` of byte `i / 8`.** The
first packet reported is the most significant bit of the first byte.

```
byte 0:   bit7 bit6 bit5 bit4 bit3 bit2 bit1 bit0
report:    i=0  i=1  i=2  i=3  i=4  i=5  i=6  i=7

byte 1:   bit7 bit6 bit5 bit4 bit3 bit2 bit1 bit0
report:    i=8  i=9 i=10 i=11 i=12 i=13 i=14 i=15
```

If `count` is not a multiple of 8, the unused low bits of the last byte MUST be zero and
MUST be ignored.

> **Why this is spelled out at this length.** Bit order is the one field in the protocol
> where two implementations can disagree and neither will ever see an error. Both parse
> the bitmap successfully; both derive a different set of arrived packets; the sender
> retransmits things that arrived and does not retransmit things that did not. The
> symptom is a link that appears to work and performs inexplicably badly.

### Arrival deltas are chained

One `i16` per set bit, in ascending index order, in units of **4 microseconds**.

The first delta is the arrival of the first reported packet relative to
`base_arrival_us`, and is therefore always **0**. Each subsequent delta is relative to
the **previous reported arrival**, not to `base_arrival_us`:

```
arrival[0] = base_arrival_us
arrival[k] = arrival[k-1] + delta[k] × 4
```

A sender MUST clamp a delta to the `i16` range before scaling, not after.

> **Why chained rather than absolute.** An `i16` in 4 µs units spans ±131 ms. Measured
> from a single base, a report covering a few hundred packets on a slow link runs out of
> range and the tail of the report is clamped into nonsense. Measured from the previous
> packet, the value being encoded is the inter-arrival gap, which stays small no matter
> how long the report is.

### The acknowledgement trailer

`ack_count` is always present, even when zero. Each acknowledgement names a reliable
message that is now completely received; see [input.md](input.md).

A sender MUST bound `ack_count`; 256 is RECOMMENDED. A receiver MUST reject a `FEEDBACK`
chunk whose declared lengths do not exactly consume the chunk body.

### `count` may be zero

A `FEEDBACK` chunk with `count = 0` carries no bitmap and no deltas. It exists to carry
acknowledgements alone, and is what a receiver sends when it has reliable messages to
acknowledge but nothing new to report about datagram arrival.

### Sending policy

A receiver SHOULD send `FEEDBACK` every 20–50 ms while traffic is flowing, and MUST send
one within 100 ms of receiving any reliable message.

A receiver MUST NOT report more packets in one chunk than fit: at
`max_datagram_size = 1200` the limit is about 540.

A receiver SHOULD NOT re-report a `transport_seq` it has already reported.

### Worked example

Ten packets from `transport_seq` 100, of which 102 and 105 did not arrive, plus one
reliable acknowledgement:

```
10002300000064000a000f4240dbc000
0000190025000d0032000f000a001900
010500000003
```

| Bytes | Value | Field |
|---|---|---|
| `10` | `0x10` | type, `FEEDBACK` |
| `0023` | 35 | length |
| `00000064` | 100 | `base_seq` |
| `000a` | 10 | `count` |
| `000f4240` | 1 000 000 | `base_arrival_us` |
| `dbc0` | | bitmap |
| `0000 0019 0025 000d 0032 000f 000a 0019` | | eight deltas |
| `0001` | 1 | `ack_count` |
| `05 00000003` | | stream 5, `msg_seq` 3 |

The bitmap decodes as:

```
db = 1101 1011      i=0 ✓  i=1 ✓  i=2 ✗  i=3 ✓  i=4 ✓  i=5 ✗  i=6 ✓  i=7 ✓
c0 = 1100 0000      i=8 ✓  i=9 ✓  i=10..15 unused, zero
```

So `transport_seq` 102 and 105 were not received. The eight deltas give arrival times:

| Index | seq | Delta | ×4 µs | Arrival |
|---|---|---|---|---|
| 0 | 100 | 0 | 0 | 1 000 000 |
| 1 | 101 | 25 | 100 | 1 000 100 |
| 3 | 103 | 37 | 148 | 1 000 248 |
| 4 | 104 | 13 | 52 | 1 000 300 |
| 6 | 106 | 50 | 200 | 1 000 500 |
| 7 | 107 | 15 | 60 | 1 000 560 |
| 8 | 108 | 10 | 40 | 1 000 600 |
| 9 | 109 | 25 | 100 | 1 000 700 |

An acknowledgement-only report:

```
10001100000000000000000000000105
00000004
```

`base_seq` 0, `count` 0, `base_arrival_us` 0, no bitmap, no deltas, one acknowledgement
naming stream 5 message 4. The body is 17 bytes.

## What a sender derives from FEEDBACK

### Round-trip time

The reporter's own `send_time_us` is in the header of the packet carrying the
`FEEDBACK`. The **hold time** is how long the reporter waited between the newest arrival
it reports and sending the report:

```
hold = reporter_send_time_us − arrival_of_newest_reported_packet
```

Both terms are on the reporter's clock, so the difference is meaningful without any
synchronisation. The original sender then computes, entirely on its own clock:

```
rtt = (now − time_that_packet_was_sent) − hold
```

A sender MUST NOT compute `rtt` from a report whose newest packet it cannot identify, and
SHOULD maintain a smoothed estimate and variance in the manner of RFC 6298.

> **Why no explicit ping is needed.** Every `FEEDBACK` already identifies a packet the
> sender sent and says how long the receiver sat on the knowledge. That is a complete
> round-trip measurement on live traffic, so a dedicated probe is only needed when there
> is no traffic at all.

### Loss

Transport loss over a window is the fraction of reported `transport_seq` values whose
bit is clear. Because the counter increments on retransmissions too, this measures the
path, not the media.

### Queuing delay

A receiver computes, for each arriving packet:

```
transit = local_arrival_time − packet.send_time_us
```

The two clocks are unrelated, so `transit` has an arbitrary constant offset — but the
offset is constant, so differences are meaningful. The minimum `transit` observed is the
baseline; `transit − baseline` is the queuing delay currently on the path.

Jitter is an exponentially weighted moving average of `|transit − previous transit|`.

## NACK (`0x11`)

Asks for specific fragments back.

```
stream:u8
entries[...]              frame_id:u32, first:u16, count:u16
```

Each entry requests `count` fragments starting at index `first`. **`count = 0` means the
whole frame**, used when the receiver has not yet learned `fragment_count`.

A sender MAY pack many entries into one chunk; a receiver MUST accept any number.

### What counts as a hole

A receiver MUST NOT `NACK` a fragment index above the highest index it has received for
that frame, except for the paced-tail timeout described below.

> **Why this rule matters more than it looks.** Without it, a receiver seeing fragment 0
> of a 436-fragment keyframe concludes that fragments 1 through 435 are missing and asks
> for all of them — while they are still sitting in the sender's pacer, waiting their
> turn. The sender retransmits hundreds of fragments that were already queued, which
> consumes the capacity the original frame needed, which causes real loss. A lossless
> link can be driven into thousands of retransmissions per keyframe this way.
>
> A hole *below* the highest index received is different: those fragments were sent, and
> something later arrived without them, so they are genuinely missing.

For the last fragments of an incomplete frame, a receiver MAY request indices above the highest received only after a pacing-aware tail timeout.
A conservative default requires both two frame intervals since first arrival and inactivity of at least the reorder window.
The receiver MUST NOT request the tail after the frame deadline and SHOULD allow additional pacing slack when backlog is known.
This timeout is a repair heuristic, not proof of loss: a slower sender or path may still be delivering the original tail.

### Timing

- First request no sooner than the reorder window, `max(1 ms, srtt / 4)`.
- Repeat no more often than `max(1.5 × srtt, 2 ms)`.
- Stop at the frame's deadline, by default three frame intervals.

### Worked example

```
110019010000000a000000030000000b
000700010000000c00000000
```

| Bytes | Value | Meaning |
|---|---|---|
| `11` | `0x11` | type, `NACK` |
| `0019` | 25 | length |
| `01` | 1 | `stream` |
| `0000000a 0000 0003` | | frame 10, fragments 0–2 |
| `0000000b 0007 0001` | | frame 11, fragment 7 |
| `0000000c 0000 0000` | | frame 12, whole frame |

## FRAME_ACK (`0x12`)

*Version 1 amendment: decoded-only acknowledgements. The reference epoch is still pending.*

Establishes reference points for long-term-reference recovery.

```
entries[...]              stream:u8, frame_id:u32
```

Each entry is 5 bytes. A receiver MUST discard a chunk whose body length is not a multiple
of 5.

A receiver MUST NOT acknowledge a frame it has not decoded successfully. Every entry
establishes a usable reference; there is no status field.

See [video.md](video.md) for the acknowledgement interval and the bound on the retained
set.

<!-- vector: feedback.frame-ack -->
```
12000a01000001f401000001f5
```

Two successfully decoded reference candidates: stream 1 frames 500 and 501.

## REFRESH_REQUEST (`0x13`)

Asks for a frame that repairs the reference chain.

```
stream:u8
reason:u8
preferred:u8
last_good_frame:u32
lost_frame:u32
req_id:u32
```

15 bytes. Reasons and preferences are in [registries.md](registries.md).

A receiver MUST reject a chunk whose `reason` or `preferred` is unassigned.
The requester reuses `req_id` within a bounded attempt; the media sender produces at most one recovery frame per identifier on that stream.
After an unsuccessful attempt expires, the requester uses a new identifier; the complete rules are in [video.md](video.md#repeating-the-request).

`last_good_frame` and `lost_frame` are informational.
The sender MUST NOT reject a fresh attempt solely because the named loss is older than a recovery frame it already produced, since that recovery frame may also have been lost.

```
13000f010000000001e0000001eb0000
0007
```

Stream 1, reason `LOSS`, preferred `LTR`, last good frame 480, lost frame 491, request
id 7.

## PING (`0x30`) and PONG (`0x31`)

```
PING:  id:u32
PONG:  id:u32, hold_us:u32
```

A receiver of a `PING` MUST reply with a `PONG` carrying the same `id` and, in
`hold_us`, the time in microseconds between the `PING`'s arrival and the `PONG`'s
transmission.

```
PING   30000400000009            id 9
PONG   31000800000009000005dc    id 9, hold 1500 µs
```

The initiator computes `rtt = (now − time_the_ping_was_sent) − hold_us`, entirely on its
own clock.

> **Why `PONG` carries the hold time.** Without it the measurement includes however long
> the responder happened to wait before replying — which on a loop that batches work can
> be a whole tick, and is not a property of the path. Reporting the hold separates the
> responder's delay from the network's. It also means the responder needs no clock the
> initiator can interpret: `hold_us` is a duration, not a timestamp.

A sender SHOULD send a `PING` when it has sent nothing for 250 ms, to keep the session
from being parked and to keep any NAT binding alive. See [reconnect.md](reconnect.md).

## Bitrate and the loss backstop

Version 0 does not control its own bitrate. The application sets it by `RECONFIGURE`;
see [control.md](control.md).

One safety mechanism is required. A sender MUST measure transport loss from `FEEDBACK`
over consecutive windows, and if loss stays above a threshold for several consecutive
windows it MUST clamp the bitrate to `BITRATE_FLOOR` and send a `STATE` message with the
`BACKSTOP` flag set. Windows of 500 ms, a threshold of 10% and four consecutive windows
are RECOMMENDED.

A sender MUST NOT raise the bitrate again on its own. Only a `RECONFIGURE` from the
application clears the backstop.

> **Why a backstop but no controller, and why no automatic recovery.** A real congestion
> controller is a large piece of work with its own failure modes, and version 0 reserves
> the seam for it rather than shipping a poor one. But a stream that sits at 80 Mbps on
> a link that cannot carry it does not merely perform badly — it saturates the path for
> everything else and never recovers, because every retransmission adds to the overload.
> The backstop is the minimum needed to make that self-limiting. It does not ramp back
> up because a controller that ramps without a model of the path is precisely the poor
> controller this version is declining to ship; returning to a working bitrate is a
> decision the application has the context to make.
