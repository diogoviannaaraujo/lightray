# Modes and client controls

> **Not yet written.** What is already decided is below; [gaps.md](gaps.md) lists the
> measurements it waits on.

It will define how a client chooses its trade-offs: a preset, and individual controls that
override it. The client proposes settings in its `INIT` and can change them at any time. The
host applies what it can and reports what it applied, as [control.md](control.md) will
describe.

## Presets

The values are provisional and can still move with measurements.

| Control | `GAME` | `DESKTOP` |
|---|---|---|
| Latency budget | 3 frame intervals (50 ms at 60 fps) | max(3 frames, 2 × RTT + 20 ms), capped at 150 ms |
| When bandwidth drops | keep the frame rate; lower quality, then resolution | keep quality; lower the frame rate, down to about 15 fps |
| Frames produced | every display refresh (60 or 120 fps) | when the screen changes, up to 60 fps |
| Chroma | 4:2:0 | the best both ends support: 4:4:4, else 4:2:2 |
| Audio frame | 5 ms | 10 ms |
| Cursor | drawn into the video; the host may ask the client to capture the pointer | drawn by the client from shapes the host sends |
| Warm window | 5 min | 15 min |
| First frame after a resume | full quality | fast-start when bandwidth is short |

## Controls a client can override

- the maximum bitrate, for example to save data on a cellular link;
- frame-rate limits, to save battery or to spend more bits on each frame;
- the display, the resolution and scaling;
- HDR;
- the FEC and retransmission policy;
- the audio bitrate, channels and redundancy;
- the microphone;
- suspending video;
- the warm window, and the expected absence a `PARK` states;
- what the first frame after a resume should be;
- statistics reporting.

## Decided

- Resolution, chroma and HDR changes force an IDR. Every other change takes effect on the next
  frame without one.
- The host may suggest a mode, for example when it detects a fullscreen game. The client
  decides.

## Waiting on

- Which chroma formats Windows hosts can offer. A Mac host can encode 4:2:2 10-bit but not
  4:4:4 ([notes/macos-host.md](../notes/macos-host.md#chroma-and-bit-depth)), which decides
  what `DESKTOP` gets.
- Whether `GAME`'s 5 ms audio frames are worth it on Windows.
- How fast Windows encoders follow a new target without an IDR.
