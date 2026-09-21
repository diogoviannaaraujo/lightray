# Audio

Audio travels on a stream of class `REALTIME`. It uses the same fragmentation,
retransmission and frame machinery as video, with two differences that follow from what
a listener notices: audio is **never decodability-gated**, and a gap is **reported**
rather than hidden.

## Codec and framing

Version 0 pins audio to **Opus** at a 48 kHz sample rate in **20 ms** packets.

Playback streams are decoded as stereo. Microphone streams are mono and decode to stereo.
Nothing on the wire says so: an Opus packet's own TOC byte describes its framing and
channel mode, and a mono stream decodes to stereo without being told to.

> **Why no audio configuration is negotiated.** Everything a decoder needs is already in
> the packet, and the sample rate and packet duration are fixed by the version. There is
> no parameter left to disagree about, so there is nothing to carry and nothing to get
> wrong. A peer that wants different audio wants a different version.

## Frames

One `frame_id` carries **exactly one Opus packet**, which is 20 ms of audio. The payload
is the Opus packet as the encoder produced it, with no length prefix and no container —
the fragment reassembly already establishes its length.

The frame header precedes it exactly as for video, with:

- `frame_type` = `AUDIO` (2)
- `ref_kind` = `NONE` (0)
- `flags` = 0; `LTR_MARK` is meaningless for audio and MUST NOT be set
- `capture_time_us` = when the audio was captured
- `ext_len` = 0; `CODEC_CONFIG` MUST NOT be present

```
0200000000000100004e200000
```

| Bytes | Value | Field |
|---|---|---|
| `02` | 2 | `frame_type`, `AUDIO` |
| `00` | 0 | `ref_kind`, `NONE` |
| `00` | 0 | `flags` |
| `00000001` | 1 | `config_generation` |
| `00004e20` | 20000 | `capture_time_us` |
| `0000` | 0 | `ext_len` |

At any reasonable bitrate a 20 ms Opus packet fits in one fragment. The machinery
handles more, but `fragment_count` will be 1 in practice.

## No decodability gating

A receiver MUST deliver every completed audio frame to the application, regardless of
whether earlier frames arrived.

> **Why.** Opus packets are independent: packet *n* is perfectly decodable whether or not
> packet *n−1* arrived. Applying the video gate to audio withholds packets that would
> have played correctly, and because the gate is waiting for a repair that the audio
> stream will never send, it does not release them later — it drops them. The audible
> result is worse than the gap it was trying to prevent, and on a stream that also
> triggers keyframe requests, it produces a keyframe storm on the video stream for no
> reason.

## Gaps

When a receiver gives up on an audio frame — its deadline passed and it is still
incomplete — it MUST report the gap to the application rather than silently skipping it.

The report carries the stream and the `frame_id` that was lost. Because each frame is a
fixed 20 ms, the application knows exactly how much audio is missing and can conceal it.

A receiver MUST report gaps in `frame_id` order, interleaved correctly with the frames it
does deliver, so that the application sees the true sequence.

> **Why the gap is reported rather than concealed by the transport.** Concealment is a
> codec-level operation: the decoder can extrapolate from its own internal state far
> better than the transport can by inserting silence. The transport's job is to say
> precisely what is missing and when, then get out of the way.

## Retransmission and deadlines

Audio is retransmitted like video, within its deadline. The deadline for a `REALTIME`
stream SHOULD be derived from the application's playout buffer rather than from the frame
interval.

> **Why the buffer and not the frame interval.** Three 20 ms frame intervals is 60 ms,
> which on many links is too short to complete even one retransmission — so the deadline
> would expire before recovery could work, and audio would never be repaired. An
> application holding 200 ms of playout buffer can afford to wait far longer, and should.
> The transport cannot know the buffer depth, so the application MUST supply it.

An implementation SHOULD allow the application to report its buffer level, and SHOULD
use it as the deadline for `REALTIME` streams. Absent that, a deadline of 200 ms is
RECOMMENDED.

## Priority

Audio is sent ahead of video and behind retransmissions and control chunks; see the
pacing rules in [video.md](video.md).

> **Why audio outranks video.** Audio is a small fraction of the bitrate, so prioritising
> it costs video almost nothing. And a dropout is more disruptive than a dropped frame:
> a listener notices a 20 ms silence far more readily than a viewer notices a repeated
> frame.

## Relating audio to video

`capture_time_us` on both streams is drawn from **the same monotonic clock on the same
machine**, so the two are directly comparable without synchronisation.

A receiver that presents both MUST align them by `capture_time_us`, not by arrival order
and not by `frame_id`. The two streams have independent identifier sequences and
different frame rates, so neither carries any timing relationship.

Version 0 does not define a presentation clock, a target buffer depth, or a policy for
what to do when the two streams drift apart. Those are application decisions; see
[gaps.md](gaps.md).
