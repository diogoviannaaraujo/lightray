# Windows validation brief

For an agent working on a Windows PC with an NVIDIA GPU, an Intel GPU, or both. It assumes no
context beyond this repository. Read all of it before starting.

**Minimum useful result:** P0-1 and P0-2 on every GPU you can reach, and
`notes/windows-host.md` written. Everything after that adds value in priority order.

## Background

Lightray is a UDP protocol for streaming a computer's screen and sound to another device and
sending input back: host → client HEVC video and Opus audio, and client → host keyboard,
pointer, gamepad and microphone. What sets it apart is **session continuity**. A client that
goes away, because its app was backgrounded or the network dropped for a moment, comes back in
about one round trip plus one frame. The host makes that possible by keeping capture and the
encoder alive while the client is away ("parked").

The repository holds the specification in `docs/` and measured platform behaviour in `notes/`.
The specification in `docs/` is version 0 and is being replaced by version 1, which is designed
but not written yet. **Where version 1 is going** below is the design; don't treat `docs/` as the
target.

The protocol serves three uses:

1. A Mac client playing games on a **Windows host** over a LAN. This brief exists for this one.
2. Mac to Mac remote desktop over the internet.
3. iPad to Mac remote desktop over the internet, where resuming after the app was in the
   background matters most.

The Apple side is measured: see `notes/macos-host.md`, `notes/ipados-client.md` and
`notes/recovery-and-resume.md`. Follow their format, and where this brief says so, their test
parameters, so the numbers can be compared.

## Where version 1 is going

**Status.** The design below is decided, though preset values can still move with evidence like
yours. The documents aren't written yet. They will be written in this order, with generated test
vectors for every wire format:

1. `packets.md` and `handshake.md`
2. `video.md` and `audio.md`
3. `feedback.md` and `rate-control.md`
4. `control.md` and `modes.md`
5. `session.md`, replacing `reconnect.md`
6. `input.md`
7. registries, conformance and open gaps

Your notes feed steps 2 to 6. Version 1 keeps most of version 0's framing and changes what the
table below describes.

**Scope:**

- Host → client carries video and audio; client → host carries input and the microphone.
- Input covers the keyboard, the pointer and gamepads. Camera, touch, pen and motion sensors
  only get reserved numbers.
- Codecs are pinned: HEVC, and Opus at 48 kHz.
- VPNs such as Tailscale or WireGuard run at the OS level and are out of scope. The default
  1200-byte datagram fits inside them.
- Hosts and clients must be implementable on any platform. Note anything Windows-specific the
  specification has to allow for.

**By area:**

| Area | Version 1 |
|---|---|
| Handshake | `Noise_NNpsk0_25519_AESGCM_SHA256` in one round trip, keyed by a pre-shared pairing secret. AES-256-GCM traffic keys, with the packet number as the nonce. A reconnecting client can take over its existing session. |
| Packets | A 16-byte header, 64-bit packet numbers, a replay window, and chunks a receiver can skip if it doesn't know them. After a client's IP address changes, the host sends at most 3× what it has received from the new address until the client's first feedback arrives; a port-only change is exempt. |
| Video | HEVC with low-delay P-frames only and no reordering: Main, Main10, and optionally 4:4:4. Frames are split across datagrams, with per-frame Reed–Solomon FEC (RFC 5510). A reference epoch counts IDRs and decoder resets, so both ends agree on what the client's decoder holds. |
| Loss recovery | FEC first; then retransmission, if it can land within the latency budget; then a recovery frame the client requests, reporting the last frame it decoded; then an IDR. The host chooses how to make the recovery frame (reference invalidation, a long-term-reference refresh or an IDR). The client declares whether its decoder accepts recovery frames that aren't IDRs. |
| Audio | Opus frames of 5, 10 or 20 ms, several per datagram, with redundant copies of recent frames. The microphone uses the same format upstream. |
| Rate control | Required: delay-based congestion control driven by per-packet arrival feedback (libwebrtc's GCC is the reference design), plus a circuit breaker. FEC and retransmissions count inside the target rate, which changes every 0.1–1 s. |
| Client control | The client proposes settings when it connects and can change them at any time. The host applies what it can and reports what it applied. Resolution, chroma and HDR changes force an IDR; every other change takes effect on the next frame without one. The host may suggest a mode, for example when it detects a fullscreen game; the client decides. |
| Session | States: active; video suspended (audio continues); parked warm (capture and encoder kept alive); parked cold (both released); expired. When it leaves, the client says how long it expects to be away, and the host clamps the warm window. On return, the client reports whether its decoder survived and which frame it last decoded. The host answers with a P-frame or long-term-reference refresh if it can, and otherwise an IDR, which may be a small "fast-start" one. A client whose app was killed must reconnect as fast as it resumes. |
| Input | The keyboard as USB HID usages (page 0x07), plus UTF-8 text and lock-state sync. The pointer as relative motion or as a position normalised to the video frame. The wheel in 1/120-notch units. Gamepads in the W3C "standard gamepad" layout, with arrival, removal and rumble. A host → client cursor channel: visibility, the shape as RGBA plus a hotspot cached by id, the position, and a request that the client capture the pointer. |

**Presets.** The client picks one, and can override any single control: maximum bitrate, frame
rate limits, display and resolution, HDR, FEC and retransmission policy, audio settings, the
microphone, video suspend, the warm window, the first frame after a resume, and statistics.

| Control | `GAME` | `DESKTOP` |
|---|---|---|
| Latency budget | 3 frame intervals (50 ms at 60 fps) | max(3 frames, 2 × RTT + 20 ms), capped at 150 ms |
| When bandwidth drops | keep the frame rate; lower quality, then resolution | keep quality; lower the frame rate, down to ~15 fps |
| Frames produced | every display refresh (60 or 120 fps) | when the screen changes, up to 60 fps |
| Chroma | 4:2:0 | the best both ends support (4:4:4, else 4:2:2) |
| Audio frame | 5 ms | 10 ms |
| Cursor | drawn into the video; the host may ask the client to capture the pointer | drawn by the client from shapes the host sends |
| Warm window | 5 min | 15 min |
| First frame after a resume | full quality | fast-start when bandwidth is short |

**Targets,** to judge which results matter:

- A client returning after about two minutes should see a new frame one round trip plus one IDR
  later: 25–70 ms on a LAN with a warm host (`notes/recovery-and-resume.md`). Any Windows step on
  that path that takes more than about 10 ms is worth flagging.
- `GAME` on busy LAN Wi-Fi: at most 0.5 freezes a minute, at no more than 15% overhead.
- After the link's capacity halves, rate control brings queueing delay back under twice its
  baseline within 1 s. Encoders must follow new targets fast enough for that.

## Open decisions your results settle

| Test | Decision | Where it lands |
|---|---|---|
| P0-1 | Which recovery methods a Windows host can use, and whether QSV can do more than IDRs | `video.md` encoder notes; open gaps |
| P0-2 | Whether a Windows host can hold a warm park, and what a cold one costs | `session.md`; warm-window defaults |
| P1-1 | Whether "no IDR except for resolution, chroma and HDR changes" holds on Windows encoders, and how fast they follow a new target | `control.md`, `rate-control.md` |
| P1-2 | Whether resumes must budget a capture restart, and whether hosts need a "video unavailable" notice | `session.md` |
| P1-3 | The cursor shape format: RGBA alone, or with an invert mask | `input.md` |
| P1-4 | Whether the keyboard needs the consumer page; what a relative mouse delta means; the wheel's units; whether a host can detect a game capturing the pointer; the rumble fields | `input.md` |
| P1-5 | Whether `GAME`'s 5 ms audio frames are worth it on Windows | `audio.md`, `modes.md` |
| P1-6 | Whether the pacing requirement is achievable on Windows | `video.md`, `rate-control.md` |
| P2-3 | HDR metadata inside the bitstream, or in a message of its own | `video.md` |
| P2-4, P2-5 | Which chroma formats a Windows host can offer, and whether it can produce a fast-start IDR | `modes.md`, `session.md` |

In `notes/windows-host.md`, answer each of these directly.

## Already known; don't redo

- Sunshine uses NVENC reference invalidation (`nvEncInvalidateRefFrames`). Its Quick Sync (QSV),
  AMF, VA-API and VideoToolbox encoders answer loss with an IDR (the `REF_FRAMES_INVALIDATION`
  flags in Sunshine's `src/video.cpp`).
- Moonlight's iOS client, which decodes with VideoToolbox, accepts reference invalidation for HEVC
  and AV1 but not H.264 (`Limelight/Stream/Connection.m` in moonlight-ios).
- VideoToolbox's long-term-reference refresh costs 3–6 KB against a 141 KB IDR at 1080p.
- A Mac host can't encode HEVC 4:4:4 through public APIs. It offers 4:2:2 10-bit (with IDR-only
  recovery) or 4:2:0 with long-term references, so how Windows hosts compare matters for
  `DESKTOP`'s chroma.
- In simulation, what a recovery frame costs barely matters on a LAN: FEC and retransmission
  repair almost every loss.

## Ground rules

- **Branches.** Work on `windows-validation`, which holds this brief and a draft NVENC probe. Push
  the branch. Don't merge it, don't push to `main`, and don't open a pull request.
- **What goes where.** Everything under `tools/windows/` stays on this branch. `notes/` is what
  the Mac side will merge into `main` after review. Put code and raw output under
  `tools/windows/`, and conclusions under `notes/`.
- **Ask the user first** before installing a driver or an SDK system-wide, running anything
  elevated, or changing a system setting (power plan, display sleep, pointer acceleration,
  cursor scheme, keyboard layouts, HDR). Restore every setting you change.
- **Batch hands-on requests.** Some tests need the user at the machine: locking and unlocking,
  approving a UAC prompt, installing a driver. Collect those and ask once.
- **Record exact versions with every result:** Windows edition and build, GPU models, driver
  versions, the NVENC API version the driver reports, the Intel media runtime (oneVPL GPU runtime
  or Media SDK), CPU, RAM, displays and refresh rates. If one machine has both GPUs, select each
  one explicitly and note which GPU drives the display.
- **Timings.** Repeat each timing at least 5 times and report p50, p99 when there are enough
  samples, and max. One machine's numbers are orders of magnitude; say so.
- **Skip what you can't run.** If a test can't be run (missing hardware, a declined permission),
  say so in the notes and move on.
- **Time-box.** If a P1 test stalls for more than an hour or two, write down what you learned and
  move on.
- **Trust observation.** If this brief is wrong about an API, a name or a behaviour, trust what
  you observe and record the discrepancy.
- **Size limits.** Don't commit any file over 2 MB, or raw video frames.
- **Commit as you go,** with messages like `tools: …` and `notes: …`.

## Tests

P0 first, then P1, then P2 if time allows.

### P0-1 Encoder recovery frames (NVENC and QSV)

**Question:** which recovery methods produce a frame that a decoder missing frames 40–45 decodes
cleanly, and what does each cost?

**Parameters,** matching the VideoToolbox streams in `notes/macos-host.md`:

- HEVC Main, 8-bit 4:2:0, 1920×1080, 60 fps, 120 frames.
- CBR with a one-frame VBV. P-frames only: no B-frames, no lookahead. Infinite GOP, so IDRs come
  only at frame 0 and on request.
- Low-latency tuning. NVENC: preset P4 with `NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY`. QSV (oneVPL):
  `LowPower` on, `GopRefDist` 1, `AsyncDepth` 1, and low-delay BRC if offered.
- Frames 40–45 are lost. The client's request reaches the host before frame 46 is encoded, so
  frame 46 is the recovery frame. When a long-term reference is used, it is frame 30.

**Content:**

- `desktop` at 20 Mb/s: the synthetic desktop in `src/common.cpp`, a port of the Mac probe's. A
  static desktop, a window dragged 11 px per frame, and text typed into the window.
- `game` at 50 Mb/s: a fixed-seed smooth-noise texture, rotated 0.5° and zoomed 0.5% per frame
  about the centre with bilinear sampling. Older frames predict it poorly, as in a game.
- If a game is installed, also run 120 frames of captured gameplay. Don't commit the raw frames.

**Scenarios:**

| Name | NVENC | QSV (oneVPL) |
|---|---|---|
| `idr` | `NV_ENC_PIC_FLAG_FORCEIDR` on frame 46 | `mfxEncodeCtrl.FrameType` = I + IDR + REF on frame 46 |
| `rfi` | `nvEncInvalidateRefFrames` for 40–45, then encode 46 | `mfxExtAVCRefListCtrl` on frame 46 (`MFX_EXTBUFF_AVC_REFLIST_CTRL`, which oneVPL also names `MFX_EXTBUFF_HEVC_REFLIST_CTRL`): `RejectedRefList` 40–45, `PreferredRefList` 39. Set `Data.FrameOrder` on every input surface |
| `rfi-long` | as `rfi`, losing 26–45 | as `rfi`, losing 26–45 |
| `ltr` | `enableLTR`; mark frame 30 (`ltrMarkFrame`, index 0); on 46, `ltrUseFrames` with bitmap 1 | `LongTermRefList` {30} on frame 30; on 46, `PreferredRefList` {30} and `RejectedRefList` 31–45 |
| `intra-refresh` (P2) | `forceIntraRefreshWithFrameCnt` on 46 | `mfxExtCodingOption2.IntRefType` and `IntRefCycleSize`, if a refresh can be started on demand |

`rfi-long` tests whether invalidation still reaches a usable reference when the loss is longer
than the reference buffer. Record the reference buffer size you configured (NVENC
`maxNumRefFramesInDPB`, QSV `NumRefFrame`).

**Record, for each encoder, content and scenario:**

- the type and size of frame 46;
- the median P-frame and IDR sizes;
- the encode latency (submit to bitstream ready) of frame 46, against the median;
- every API error or warning, for example `NV_ENC_ERR_UNSUPPORTED_PARAM` or
  `MFX_WRN_INCOMPATIBLE_VIDEO_PARAM`;
- whether a control was silently ignored.

**Verification.** Decode each stream twice, complete and with the lost access units removed, and
compare per-frame hashes.

- **PASS:** every frame from 46 on is identical in both decodes, and the lossy decode reports no
  errors.
- **LATE n:** identical only from frame n > 46. Expected for intra refresh.
- **FAIL:** anything else. Quote the decoder's errors.

How:

- To split Annex B into access units: a VCL NAL unit (type 0–31) whose
  `first_slice_segment_in_pic_flag` (the first bit after the 2-byte NAL header) is 1 starts a new
  picture. Parameter sets, SEI and access unit delimiters belong to the picture that follows them.
- Reference decoder: ffmpeg's software HEVC decoder:
  `ffmpeg -v error -i in.hevc -fps_mode passthrough -pix_fmt yuv420p -f framemd5 out.txt`.
- The lossy decode must output exactly 114 frames (100 for `rfi-long`). Its frame k is original
  frame k before the gap, and k + 6 (or k + 20) after it. A different count is itself a finding.
- P1: repeat with each GPU's hardware decoder (`-hwaccel d3d11va`, choosing the adapter). HEVC
  decoding is bit-exact, so the hashes must match the software decode.

**Output** goes under `results/recovery/`:

- `<encoder>-<content>-<scenario>.hevc` and a `.json` manifest for every stream. The Mac side
  will re-verify the `.hevc` files with VideoToolbox on a Mac and an iPad, so commit every one
  under 2 MB.
- One verdict line per stream.

The manifest format, which the Mac verifier reads:

```json
{
  "encoder": "nvenc",
  "device": "the GPU name the API reports",
  "scenario": "desktop-rfi",
  "width": 1920,
  "height": 1080,
  "fps": 60,
  "lost": [40, 41, 42, 43, 44, 45],
  "recovery": 46,
  "notes": "preset, tuning, rate control, reference buffer size, driver version",
  "frames": [
    { "index": 0, "bytes": 118831, "keyframe": true },
    { "index": 1, "bytes": 2556, "keyframe": false }
  ]
}
```

`frames` lists every access unit in order. The VideoToolbox streams in `reference/` show a
complete example.

### P0-2 Keeping an encoder warm through a park

**Question:** can a Windows host keep an encoder session idle through a park and resume with a
P-frame, and what does the first frame after the idle cost?

For each encoder, with `desktop` content at 1080p60 20 Mb/s and at 2160p60 40 Mb/s:

1. Cold start: time session creation, initialisation and the first IDR (5 runs).
2. Encode 60 frames. Record the p50 latency and size of the P-frames.
3. Stop encoding for 5, 120 and 300 s. At 1080p, also once for 900 s.
4. Encode frame 61 in three separate runs: a P-frame of the unchanged screen, a P-frame of a
   changed screen, and a forced IDR. Record latency, size and any error.
5. Check that every stream decodes without errors.

For comparison, from `notes/macos-host.md`: after 120 s idle, VideoToolbox produced a 1080p IDR
in 7.2 ms, and an unchanged-screen P-frame was 1.0 KB.

Also run the 120 s idle once with the display turned off (by power settings or
`SC_MONITORPOWER`) and once with the session locked (Win+L). Record whether the encoder session
survives.

P2: open encoder sessions until one fails, to find the concurrent-session limit. It bounds how
many parked clients a host can keep warm.

### P1-1 Retargeting without an IDR

**Question:** do bitrate and frame-rate changes take effect on the next frame without an IDR?

At 1080p, with both contents, for 20 s each:

- **Bitrate:** change the target every second, 20 → 10 → 40 → 5 → 20 Mb/s. NVENC:
  `nvEncReconfigureEncoder` with `resetEncoder = 0` and `forceIDR = 0`. QSV:
  `MFXVideoENCODE_Reset` with `mfxExtEncoderResetOption.StartNewSequence` off.
- **Frame rate:** change it every second, 60 → 30 → 120 → 60, both the configured rate and the
  rate you submit frames at.
- **Resolution:** change 1080p → 720p → 1080p. An IDR is expected. Measure the time from the call
  to the first frame at the new size, and whether NVENC can do it without recreating the session
  (`maxEncodeWidth`, `maxEncodeHeight`).

Record: every I or IDR frame nobody asked for; the frames until a 250 ms moving average of bytes
per second is within 10% of the new target; the reconfigure call's latency; any errors.

P2: submit frames only when the content changes (60 fps bursts separated by 0.5–3 s pauses) at a
fixed configured frame rate. Is the first frame after a pause oversized, and does the bitrate stay
on target? `DESKTOP` produces frames this way.

### P1-2 Capture: restart cost and what breaks it

**Why:** parking assumes capture stays alive for minutes. If Windows breaks it routinely, a
resume must budget for a capture restart, and version 1 may need a host → client "video
unavailable" notice.

For Desktop Duplication (`IDXGIOutputDuplication`) and Windows.Graphics.Capture, measure:

- the time to the first frame of a new capture session, cold and warm (5 runs each);
- frame delivery on a static screen and on 60, 120 and 144 Hz content;
- which timestamp each API gives (`LastPresentTime`, `SystemRelativeTime`), compared with when
  you received the frame.

Then, for each event below, record what the API reports and how long until frames flow again,
re-creating the capture if needed:

- lock and unlock;
- a UAC prompt (the secure desktop);
- display off and back on;
- a resolution change, and a refresh-rate change;
- HDR on and off;
- a fullscreen-exclusive D3D app starting and exiting (a small test app is fine);
- sleep and wake, only if the user agrees. The session is expected to end.

Output: a table of event and API against behaviour and recovery time.

### P1-3 Cursor shapes

**Question:** can RGBA plus a hotspot represent every Windows cursor, or does the cursor channel
need an inversion (XOR) mask?

Read shapes with `IDXGIOutputDuplication::GetFramePointerShape` (monochrome, colour and masked
colour) and with `GetCursorInfo` plus `GetIconInfoEx`. Cover the standard cursors: arrow, I-beam,
wait, app-starting, cross, hand, the four resize arrows, move, not-allowed, help, pen and
up-arrow. For each, record:

- shape type, pixel size and hotspot;
- whether any pixel inverts the screen (monochrome AND = 1 with XOR = 1, or a masked-colour pixel
  with the mask set);
- for animated cursors, the frame count and interval the API reports;
- how often the shape changes while hovering text and links in a browser.

Under these conditions:

- the default scheme at 100% and 200% display scale;
- pointer size 1 and 3;
- the Windows Black and Windows Inverted schemes.

Also sample the custom cursors in a browser, Office or Notepad, VS Code and Explorer.

Recommend one of: RGBA is enough; RGBA plus a per-pixel invert flag; or the host approximates
inverting pixels.

### P1-4 Input injection

Use `SendInput` from a normal (not elevated) process. Receive in a test window that logs
`WM_KEYDOWN`, `WM_CHAR` and `WM_INPUT` (raw input), and in a game or a DirectInput or XInput
tester where one is available.

**Keyboard:**

- Build the mapping from USB HID usages (page 0x07, 0x04–0xE7) to set-1 scan codes with the
  extended flag. Inject each with `KEYEVENTF_SCANCODE` and check the VK and scan code that arrive,
  under the US layout and one non-US layout (ask before adding one). List any usage with no
  scan-code path.
- Media, volume and browser keys (HID consumer page 0x0C): can they be injected, and how? This
  decides whether version 1 needs the consumer page.
- Text with `KEYEVENTF_UNICODE`, including characters outside the BMP (emoji, as surrogate pairs),
  into Notepad, a browser field, and a game chat if available.
- Lock keys: do injected Caps, Num and Scroll Lock presses set the state reliably (`GetKeyState`)?
- Confirm that a non-elevated process can't inject into an elevated window, and that nothing
  reports the failure. Note what a host needs instead (`uiAccess`, elevation, a service), without
  installing anything.

**Pointer:**

- **Absolute:** `MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK`, normalised to 0–65535. Measure
  the pixel error across the virtual desktop at 100, 150 and 200% scale, and with two monitors if
  available. Give the exact formula that lands on the intended pixel.
- **Relative:** inject moves of 1, 5, 20 and 100 counts with "Enhance pointer precision" on and
  off (ask before toggling it). Record the cursor's displacement and what `WM_INPUT` reports.
  This decides what a relative delta on the wire means, raw counts or pointer pixels, and whether
  hosts must compensate for acceleration.
- **Fractions:** injected moves are whole counts. Note how a host should carry fractional deltas.
- **Wheel:** `MOUSEEVENTF_WHEEL` and `MOUSEEVENTF_HWHEEL` with deltas of 120, 60, 30, 15 and 1.
  Which apps scroll smoothly on deltas below 120: a browser, Explorer, Notepad, VS Code, a game?
- **Buttons 4 and 5:** `XBUTTON1` and `XBUTTON2`.

**Pointer capture.** The host uses outside signals to ask the client to capture the pointer.
Write a test app that behaves like a first-person game: it hides the cursor, clips it to its
window, re-centres it every frame with `SetCursorPos`, and reads `WM_INPUT`. Using that app, and
a real game or two if installed, find which signals a host can see from outside, and how quickly:

- the cursor hidden (`GetCursorInfo`);
- a clip rectangle (`GetClipCursor`);
- a foreground window covering the monitor;
- the re-centring pattern.

**Gamepad,** only if the user agrees to install ViGEmBus; otherwise from documentation only:

- ViGEmBus is retired but is what Sunshine uses. Is there an in-box way to create a virtual
  XInput controller?
- Map the W3C standard gamepad to an Xbox 360 report and check it in `joy.cpl` or an XInput
  reader: sticks from −1…1 to int16 with Y inverted, triggers from 0…1 to 0–255, buttons, D-pad.
- Rumble: the rate and latency of ViGEm's notifications (large and small motor, 0–255) when a test
  app calls `XInputSetState`. Trigger rumble can't be reached through the Xbox 360 target; note
  what the DualShock 4 target adds (rumble, light bar).
- Add and remove a virtual pad while a game or test app runs.

### P1-5 Audio capture

**Why:** `GAME` uses 5 ms Opus frames. If Windows delivers audio only every 10 ms, 5 ms frames add
packets without cutting latency.

- WASAPI loopback on the default output device, in shared mode: the device and engine periods
  (`GetDevicePeriod`, `IAudioClient3::GetSharedModeEnginePeriod`), and the packet cadence and
  size actually delivered. Can loopback deliver packets of 5 ms or less?
- Capture latency: play a click, find it in the loopback stream, and compare the QPC time of the
  play call with the packet's `qpcPosition`.
- What loopback delivers while nothing plays: no packets, or packets flagged silent.
- Switching the default device, or unplugging headphones, mid-capture: the error
  (`AUDCLNT_E_DEVICE_INVALIDATED`) and the time to restart.
- Exploration only: how a host could present the client's microphone as a Windows recording
  device (existing virtual audio drivers, or writing one). Don't install anything.

### P1-6 UDP pacing

- Send 1200-byte datagrams at 50, 100, 200 and 400 Mb/s, paced every 1 ms and every 0.25 ms,
  three ways:
  - a busy-wait on QPC;
  - a high-resolution waitable timer (`CREATE_WAITABLE_TIMER_HIGH_RESOLUTION`);
  - `timeBeginPeriod(1)` with `Sleep`.

  Record the achieved send-gap distribution, the CPU use, and how a full non-blocking socket
  behaves (`WSAEWOULDBLOCK`), with the default `SO_SNDBUF` and with 8 MB.
- UDP segmentation offload (`UDP_SEND_MSG_SIZE`) with `WSASendMsg` batches: CPU use at 400 Mb/s
  with and without it.
- If another machine on the LAN can receive, measure arrival gaps there too.
- DSCP: does `IP_TOS` take effect without a QoS policy? What does qWAVE allow without admin?

### P2-1 AEAD cost

AES-256-GCM seal and open of a 1200-byte datagram with BCrypt, and ChaCha20-Poly1305 if this
Windows build has it: p50 µs per operation.

### P2-2 Windows as a client

- Verify the VideoToolbox streams in `reference/` (an IDR recovery and two long-term-reference
  recoveries, in the same layout as P0-1) with each GPU's D3D11VA decoder and in software. Report
  PASS, LATE or FAIL for each. This covers a Mac host streaming to a Windows client.
- Measure decoder creation (cold and warm), first-IDR decode and steady P-frame decode latency at
  1080p, 1440p and 2160p with D3D11VA on each GPU.
- If you do this, write `notes/windows-client.md`.

### P2-3 HDR

- How each encoder emits mastering-display and content-light-level SEI for HEVC Main10 with PQ:
  NVENC `outputMasteringDisplay` and `outputMaxCll`; oneVPL `mfxExtMasteringDisplayColourVolume`
  and `mfxExtContentLightLevelInfo`.
- How an HDR desktop is captured (FP16 through Desktop Duplication or Windows.Graphics.Capture)
  and converted to P010.

This decides whether version 1 can carry HDR metadata inside the bitstream or needs a message of
its own.

### P2-4 Encoder capabilities

For each GPU, record: HEVC 4:4:4 (8 and 10-bit), 4:2:2 10-bit, Main10, maximum resolution and
frame rate, reference and long-term-reference counts, intra refresh, and temporal layers. Encode
1080p60 4:4:4 once (latency, IDR size), and check whether `rfi` and `ltr` still work in 4:4:4.

### P2-5 Fast-start IDR

**Question:** can each encoder produce, on request, an IDR of about 40 KB at 1080p (against
~140 KB normally), and then return to full quality within a few frames?

This is the small first frame a host sends when a client resumes over a slow link. Use whatever
each API offers: a per-frame QP, a temporary QP range, or a maximum I-frame size (for example
QSV's `MaxFrameSizeI`). Record the IDR's size and PSNR against a full-quality IDR of the same
frame, and how many frames it takes for PSNR to come back within 1 dB.

## Exploration (reading only)

Read Sunshine's Windows host (github.com/LizardByte/Sunshine: `src/platform/windows/`,
`src/nvenc/`, `src/video.cpp`) and record how it handles:

- the choice of capture API, and the secure desktop (it runs as a service);
- the cursor;
- relative mouse and pointer capture;
- gamepads and the microphone;
- HDR metadata;
- pacing;
- NVENC and QSV settings, and whether it changes bitrate mid-stream.

Compare each with **Where version 1 is going**, and list what Lightray should adopt or must
handle.
Cite files and lines with a commit hash. Also list, without installing anything, the virtual
display and gamepad drivers used by Apollo (a Sunshine fork) and Parsec.

## Deliverables

On the `windows-validation` branch:

- **`notes/windows-host.md`,** the summary:
  - It opens with what was tested, what wasn't, and the three most important findings.
  - Then a setup table (hardware and software versions), and findings per test with tables.
  - Then an answer to each row of **Open decisions your results settle**, including "not
    tested".
  - Then "Implications" bullets in the style of `notes/ipados-client.md`, and open questions.
  - Every number must trace to a file in `tools/windows/results/`.
- **`notes/windows-client.md`,** only if P2-2 was done.
- **`tools/windows/`:** the code (CMake, with a README on how to build and run it) and
  `results/`: condensed raw output, the recovery streams and their manifests.

Push the branch when you're done.

## Tooling

- Visual Studio 2022 or its Build Tools, with C++, CMake and the Windows SDK.
- nv-codec-headers (MIT, header-only), `n12.2.72.0` or newer as long as the driver supports its
  API version. Its dynamic loader means no CUDA toolkit is needed.
- oneVPL: Intel's `libvpl` dispatcher (MIT), for example through `vcpkg install libvpl`. The
  runtime comes with the Intel graphics driver; record which runtime is used.
- A recent ffmpeg build, for decoding and hashing.
- Python 3 for scripts.
- Optional: `nvidia-smi`, PresentMon.

`src/` holds a draft:

- `common.h` and `common.cpp`: scenario constants, the synthetic desktop and the manifest writer.
- `nvenc_probe.cpp`: the `idr`, `rfi`, `ltr` and `intra-refresh` scenarios through NVENC.

It has only been syntax-checked, on a Mac, against nv-codec-headers `n12.2.72.0`. It has never
been compiled or run on Windows, and there is no `main.cpp`, QSV probe or `CMakeLists.txt` yet.
Use it, fix it or replace it.
