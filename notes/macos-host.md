# Mac host

VideoToolbox behaviour a Mac host depends on. Measured on an Apple M4 (10 cores) on 24 September
2026: the resume path on macOS 26.5, recovery and chroma on macOS 27.0. The rate-control rows come
from earlier checks on the same Mac on macOS 26.5, on 19 September 2026. These are single runs:
read the numbers as orders of magnitude.

Unless a row says otherwise, streams are HEVC from the hardware encoder with
`kVTVideoEncoderSpecification_EnableLowLatencyRateControl`, `RealTime` and no frame reordering,
encoding a synthetic desktop: a static desktop with a window being dragged across it and text
being typed into the window.

## The resume path

| Stream | Cold first IDR | IDR after the encoder idled 5 s / 120 s | IDR size | P-frame, screen unchanged | P-frame, screen changed |
|---|---|---|---|---|---|
| 1080p, 20 Mb/s | 26.6 ms | 7.6 / 7.2 ms | 142 KB | 1.0 KB | 136 KB |
| 1440p, 20 Mb/s | 34.1 ms | 11.2 ms / not run | 165 KB | 1.5 KB | 197 KB |
| 2160p, 40 Mb/s | 44.2 ms | 22.1 / 29.6 ms | 244 KB | 2.9 KB | 302 KB |

- **A warm encoder is what makes a resume cheap.** Creating and preparing a compression session
  takes under 1 ms, but its first IDR takes 22–46 ms (p50; up to 101 ms in the worst of five
  runs). A session kept alive and idle for 120 s produced a 1080p IDR in 7.2 ms.
- At 2160p the first frame after 120 s idle was slower than steady state (29.6 ms against 20.3 ms).
- **A P-frame resume pays only when the screen barely changed:** 1–5 KB for an unchanged screen,
  but 136–302 KB, as much as an IDR, when it changed.
- The first `VTDecompressionSession` in a process took 75–103 ms to create, later ones 3–17 ms.
  The first IDR decoded in 2.5–7.9 ms.

## Loss recovery with long-term references

Three 1080p, 20 Mb/s streams lose frames 40–45 and recover at frame 46. Each was decoded twice by
VideoToolbox, complete and with the lost frames removed, and frames 46–119 were identical in both
decodes for all three:

| Recovery | Frame 46 |
|---|---|
| IDR | keyframe, 141.3 KB |
| Long-term-reference refresh, receiver acknowledges every frame | P-frame, 3.0 KB |
| Long-term-reference refresh, receiver acknowledges every 250 ms | P-frame, 6.3 KB |

How the encoder has to be driven:

- Set `kVTCompressionPropertyKey_EnableLTR`. Frames the encoder marks as long-term carry a token
  in the `kVTSampleAttachmentKey_RequireLTRAcknowledgementToken` sample attachment.
- When the receiver reports such a frame decoded, pass its token once, in
  `kVTEncodeFrameOptionKey_AcknowledgedLTRTokens` on the next frame encoded. **Re-sending an
  already acknowledged token with every frame made the encoder emit a keyframe with new parameter
  sets.**
- After a loss, encode the next frame with `kVTEncodeFrameOptionKey_ForceLTRRefresh`: it
  references only an acknowledged long-term frame.

## Chroma and bit depth

| Profile requested | Low-latency mode | Normal mode (`RealTime`, no reordering) |
|---|---|---|
| Main | 4:2:0 8-bit, long-term references available | 4:2:0 8-bit, `EnableLTR` rejected (`-12900`) |
| Main10 | 4:2:0 10-bit, long-term references available | 4:2:0 10-bit, `EnableLTR` rejected |
| Main 4:2:2 10 | **4:2:0 8-bit**: the profile is accepted and ignored | 4:2:2 10-bit, `EnableLTR` rejected |

- The public API has no HEVC 4:4:4 encode profile: `kVTProfileLevel_HEVC_*` offers Main, Main10,
  Main 4:2:2 10, Monochrome and Monochrome10.
- Steady-state encode latency at 1080p: 8.4 ms p50 for low-latency Main, 7.3 ms for normal-mode
  Main, and 7.2 ms for normal-mode 4:2:2 10-bit.
- So a Mac host can offer either 4:2:2 10-bit, with sharper colour edges and IDR-only recovery,
  or 4:2:0 with long-term-reference recovery, not both.

## Rate control in low-latency mode

- `DataRateLimits` is accepted and ignored: the output was byte-identical to an uncapped run.
  `ConstantBitRate` and `PrioritizeEncodingSpeedOverQuality` are rejected (`-12900`). There is no
  per-frame size cap: at 4 Mb/s the p99 P-frame was 3.0× the per-frame budget and the largest
  5.7×.
- **Under a tight budget the encoder skips frames** and produces no output for them (1080p60: 8–10
  of 180 frames at 2 Mb/s, 2 at 4 Mb/s).
- With a missing reference, the HEVC decoder returns `kVTVideoDecoderBadDataErr` instead of
  showing a damaged picture, so a client knows when it needs a recovery frame. (H.264 decodes
  garbage silently.)
- HEVC encodes 4K120 in low-latency mode at ~19 ms per frame; H.264 produced no frames at 4K120.

## Implications

- **Keep the encoder session alive through a park.** A cold encoder adds 20–40 ms to the first
  frame.
- **Prefer long-term-reference recovery on 4:2:0 streams:** a 3–6 KB refresh against a 141 KB IDR.
- **4:2:2 10-bit gives that up for IDR-only recovery,** so it should be the client's choice.
- **The host's pacing, not the encoder, has to bound bursts,** and the host must not assume
  one encoded frame per captured frame.
