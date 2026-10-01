# Lightray for macOS

The client now has an in-video performance HUD and optional Command/Control swapping for Windows hosts; see [metrics, keyboard shortcuts, and validation](../docs/windows/client-ux-progress.md).
Use `--swap-command-control` for Command+C/V in Windows, `--no-stats` to start without the HUD, or the View and Input menus to change these settings per window.
Control+Option+Command+Esc releases remote input; click the video to resume, and Control+Option+Command+M toggles the HUD.

A first implementation of the protocol in [`docs/`](../docs/README.md), Mac to Mac: video from the
host, any number of its displays at once, and keyboard and mouse from the client. Audio, the
microphone, park and resume, and the other things listed under [Not yet](#not-yet) come later.

## Build and test

Requires macOS 14 or later and Swift 6.

```bash
swift build -c release --package-path macos
```

```bash
swift test --package-path macos
```

The tests reproduce every value in [`tools/vectors/vectors.json`](../tools/vectors/vectors.json),
parse and re-encode the hex examples in the version 0 documents, decode the IDR published in
[`video.md`](../docs/video.md) with VideoToolbox, and run a host against a client over a simulated
path with loss, jitter and address changes. The names of the conformance tests they cover are in
the test files.

## Graphical client

Start `macos/.build/release/lightray-client` without a host to open Computers.
Enter a hostname/IP and port, import the pairing file supplied by the host, choose a local display, and connect.
Remember this computer stores public metadata separately from the protected pairing file.
The session menu offers Disconnect, which returns to Computers; closing the last stream does the same in this mode.
The launcher returns to Computers with guidance if authentication does not succeed within 12 seconds after network setup.
`--launcher` forces this mode with optional CLI defaults; `--no-host-catalog --no-preferences` isolates laboratory runs from saved hosts/settings.
Monitor preferences use persistent display UUIDs, with an available-display fallback after disconnection.
See the [connection and WGC validation report](../docs/windows/connection-capture-progress-2026-10-01.md) for tested behavior and open onboarding/compatibility gates.

## Run

**On the host**, create a pairing once and copy the token it prints:

```bash
macos/.build/release/lightray-host pair
```

Then start it:

```bash
macos/.build/release/lightray-host
```

The host needs two permissions, granted to the app you start it from, such as Terminal, in System
Settings › Privacy & Security:

- **Screen & System Audio Recording**, to capture the displays;
- **Accessibility**, to post keyboard and mouse events.

macOS also asks, the first time and again from time to time, whether `lightray-host` may "bypass
the system private window picker": that is the confirmation for capturing the screen directly
rather than through the picker. Allow it.

macOS lets only one running process per executable file capture the screen: a second
`lightray-host` started from the same file, on another port say, gets no picture until the first
exits. Run a copy of the binary for a second host.

**On the client**, pass the token once; it is remembered:

```bash
macos/.build/release/lightray-client host.example --pair lr1-…
```

The client opens a window on the host's primary display. In a client window every key goes to the
host, Command shortcuts included, except those macOS keeps for itself (Command-Tab, Mission
Control). **⌃⌥⌘Q quits the client.** The host draws its cursor into the video, so the local cursor
is hidden over the window.

### Several displays

Each window shows one of the host's displays on a video stream of its own
([displays.md](../docs/displays.md)). The **Displays** menu opens another display in a new window,
brings forward the one showing it, or switches the current window to a different display. Closing
a window stops its stream; closing the last one quits in direct CLI mode or returns to Computers in launcher mode. Two windows can show the same display.

`--all-displays` opens every display at start, and `--show ID` a given one, by the id the host logs
when it starts. The client proposes 4 video streams, so 4 windows at once; `--streams N` changes
that. The host accepts every stream, starts capture and an encoder for each display a window asks
for, and refuses a display only when one of them cannot start: the hardware sets the limit. Each
stream runs at the full `--bitrate`.

The host keeps capture and the encoders running for 5 minutes after a session ends, so that a
client coming back gets its first frame from a warm encoder (`--warm S` to change it). When a
display is unplugged, the windows showing it close; when its resolution changes, they get a
keyframe of the new size. When the host's capture stops on its own (macOS reconfigured the
display: a Screen Sharing session that added a virtual display ended, say), the host starts it
again, retrying every 2 s at most while it fails, and the window carries on. If the host stops
showing the last window's display because that display went away, the window moves to the
primary display; otherwise it stays open and says so, rather than the client seeming to quit.
The host reads its display list again at each session start and checks it every second, since
macOS does not always announce a change: a Screen Sharing session in its high-performance mode
replaces the displays with a virtual one while it lasts, and takes it away when it ends.

Both ends keep their tokens in `~/Library/Application Support/Lightray/`, readable only by the user.

### Options

| Host | |
|---|---|
| `--port N` | UDP port, default 7373 |
| `--fps N` | Frame rate cap, default 60 |
| `--bitrate N` | Video bitrate in Mb/s for each display shown, parity included, default 20 |
| `--scale X` | Capture at X times each display's pixel size |
| `--mtu N` | Largest datagram accepted, default 1200 |
| `--log-input` | Log input messages instead of injecting them |
| `--no-input` | Ignore input |
| `--test-pattern WxH` | Offer two synthetic displays of that size instead of the real ones; needs no permission |
| `--warm S` | Keep capture and encoders running S seconds after a session ends, default 300 |
| `--fec PERCENT` | Reed–Solomon parity per block of fragments, for clients that offer FEC; 0 turns it off. Default 10 |
| `--fec-min N` | At least N parity fragments per block, default 1. `--fec 20 --fec-min 2` is Sunshine's setting |
| `--drop-rate X` | Drop a fraction X of arriving datagrams |

| Client | |
|---|---|
| `host[:port]` | Name or address; `[::1]:7373` for IPv6 with a port |
| `--pair TOKEN` | Use and remember a pairing token |
| `--mtu N` | Datagram size to propose, default 1200 |
| `--streams N` | Video streams to propose: how many displays can be shown at once, default 4 |
| `--all-displays` | Show every display of the host at start |
| `--show ID` | Show that display at start; repeat for more windows |
| `--drop-rate X` | Drop a fraction X of arriving datagrams |
| `--snapshot FILE` | Write each stream's picture to a PNG 3 s after its first; streams after the first add `-<stream>` to the name |
| `--exit-after S` | Quit after S seconds |
| `--no-fec` | Do not offer FEC; the host then sends no parity |

To try it on one Mac without permissions, run the host with `--test-pattern 1920x1080
--log-input` and the client against `127.0.0.1 --all-displays`: two windows, one per pattern. Running both against a real screen on the same
Mac mirrors the client window into itself, and injected input chases the local pointer; use
`--log-input` there.

## What is implemented

| Document | State of the document | Here |
|---|---|---|
| [handshake.md](../docs/handshake.md) | Version 1 | All of it except taking over a session: `NNpsk0`, the padded INIT with don't-fragment, the INIT cache answered with the identical RESPONSE, the timestamp window, retransmission, the 64-packet early buffer, `SESSION_UNKNOWN` with its rate limit and constant-time check |
| [packets.md](../docs/packets.md) | Version 1 | All of it: sealing, packet-number reconstruction, the 2048 replay window, chunk parsing with must-ignore and contained errors, stream direction and class checks, rebinding on the strictly newest packet, the 3× cap on a new IP address until a `FEEDBACK` validates it |
| [video.md](../docs/video.md) | Version 0 text, FEC as version 1 plans it | The frame header with `CODEC_CONFIG`, fragmentation at `stride = mds − 51`, reassembly with its bounds, ordered delivery behind the `PREVIOUS` gate, the retransmission store, pacing, and IDR recovery. FEC scheme 1, per-frame Reed–Solomon after RFC 5510, in a [provisional](#provisional-fec-format) form; recovery in the order FEC, retransmission, IDR. No long-term references |
| [feedback.md](../docs/feedback.md) | Version 0 text | `FEEDBACK` with RTT from the hold time, `NACK` for what parity cannot cover, `REFRESH_REQUEST` attempts, `PING`/`PONG`. A tail counts as lost once a later frame arrives, with the tail timeout only as a fallback. No loss backstop |
| [input.md](../docs/input.md) | Version 0 text | `RELIABLE` streams with acknowledgements in `FEEDBACK`; one stream per device; pointer motion merged at 1 ms. The payloads are [provisional](#provisional-input-format) |
| [displays.md](../docs/displays.md) | Version 1, byte layouts pending | Several video streams, each independent; the display list; binding a stream to a display, two streams to one display, and the host binding its primary display to the first stream; pointer positions naming a display; hot-plug and mode changes. The messages are [provisional](#provisional-control-messages). Not yet: bindings in the INIT, weights, per-stream settings other than the display |

Where version 1 has decided something but not yet written it, this follows the version 0 text on
the wire. It will change as the documents are rewritten.

### Provisional input format

`input.md` leaves input payloads to the application until version 1 defines them. This is this
implementation's format, not the protocol's, following the direction version 1 has taken: keys as
USB HID usages, the pointer as a position normalised to one of the host's displays.

The client proposes this stream table:

| id | Kind | Direction | Class | Carries |
|---|---|---|---|---|
| 1 | `VIDEO` | host → client | `MEDIA` | the first display |
| 4 | `INPUT` | client → host | `RELIABLE` | keyboard |
| 5 | `INPUT` | client → host | `RELIABLE` | pointer |
| 16, 17, … | `VIDEO` | host → client | `MEDIA` | further displays, one stream each, `--streams` in all |

Each input event is one reliable message; its first byte is the type.

| Type | Body | Meaning |
|---|---|---|
| `0x01` `KEY` | `usage:u16, flags:u8` | A usage on HID page 0x07. Flags: bit 0 down, bit 1 autorepeat |
| `0x10` `POINTER` | `x:u16, y:u16, display:u32` | Position on the host's display `display`: 0 is its left or top edge, 65535 its right or bottom. A `display` of 0, or none, means the primary display; an unknown one is ignored |
| `0x11` `BUTTON` | `button:u8, down:u8` | 1 left, 2 right, 3 middle, 4 back, 5 forward |
| `0x12` `SCROLL` | `dx:i16, dy:i16, units:u8` | Units: 0 is 1/120 of a wheel notch, 1 is pixels. Positive `dy` scrolls up, as the client's Mac reports it after its own natural-scrolling setting; the host posts it unchanged |

A receiver ignores a message of unknown type, and bytes after the fields it knows. Caps Lock is
sent as a press and release per toggle, and the host keeps the lock state.

### Provisional control messages

[displays.md](../docs/displays.md) defines what these mean; control.md will give them their bytes
when it is rewritten. Until then they are reliable messages on stream 0 in the shape of
control.md's version 0 text, `msg_type:u8, req_id:u32, scope_stream:u8`, then TLVs of
`type:u8, length:u16, value`, with numbers from `0xF0` up for what that text does not define.

| Message | Direction | `msg_type` | `req_id` | `scope_stream` | TLVs |
|---|---|---|---|---|---|
| Select a display | client → host | `1` (`RECONFIGURE`) | the client's | a video stream | `DISPLAY` |
| Display selected | host → client | `2` (`RECONFIGURE_RESULT`) | the request's | that stream | `DISPLAY`: what it shows now |
| Stream display | host → client | `3` (`STATE`) | 0 | a video stream | `DISPLAY` |
| Displays | host → client | `0xF0` | 0 | 0 | one `DISPLAY_INFO` per display |

| TLV | Type | Value |
|---|---|---|
| `DISPLAY` | `0xF0` | `display_id:u32`, 0 for none |
| `DISPLAY_INFO` | `0xF1` | `display_id:u32, flags:u8` (bit 0 primary, bit 1 HDR), `width:u16, height:u16` in pixels, `refresh_mhz:u32`, `x:i32, y:i32, layout_width:u32, layout_height:u32` in the host's desktop points, then the name in UTF-8, at most 64 bytes |

A `display_id` is the display's `CGDirectDisplayID`. The host sends the list and a `STATE` for
every video stream when a session starts, and the list again whenever a display is added, removed
or changed.

### Provisional FEC format

Version 1 names per-frame Reed–Solomon (RFC 5510) as FEC scheme 1 but has not written its
bytes. Until [video.md](../docs/video.md) does, this implementation uses the following, which
follows Sunshine and Moonlight in shape.

- **Negotiation.** The client offers bit 2 (`FEC`) of the `CAPABILITIES` parameter (type 3, one
  byte) in its INIT; the host puts the bits it accepts in the RESPONSE, and sends parity only
  then. Version 0 reserves the bit.
- **The code.** RFC 5510 §8: GF(2⁸) with 1 + x² + x³ + x⁴ + x⁸, the systematic generator
  `V_{k,k}⁻¹ · V_{k,n}` with `v_ij = α^(i·j)`, applied byte by byte to shards of `stride` bytes;
  the last data fragment is zero-padded for coding. Any k of a block's k + p shards rebuild it.
- **Blocks.** A frame's N data fragments are split as RFC 5052 §9.1 does, into `ceil(N / kMax)`
  blocks of near-equal length, the longer ones first. The host uses the longest blocks that stay
  within 255 shards at its percentage F, `kMax = min(255 − min_parity, ⌊25500 / (100 + F)⌋)`, and
  gives every block `p = max(min_parity, ceil(longest × F / 100))` parity fragments. There is no
  limit on blocks, so keyframes stay protected.
- **Fragments.** Every fragment of a protected frame carries the FEC extension
  `01 05 01 kMax:u8 p:u8 last_len:u16` in place of `01 01 00`, so `stride = mds − 55`.
  `last_len` is the last data fragment's true length, to cut a rebuilt one back to size. A
  fragment whose values differ from the frame's first is discarded.
- **Parity fragments** set flag bit 3 (`PARITY`) and keep `fragment_count` = N; their
  `fragment_index` is b·p + j for block b's j-th parity, below `blocks × p`, and each is exactly
  `stride` bytes. The host sends each block's data, then its parity. Parity is never
  retransmitted, and a `NACK` names data fragments only.
- **Rate.** The encoder gets `bitrate × 100 / (100 + F)`, so that parity fits in `--bitrate`.

A client rebuilds a block as soon as it holds k shards. It asks only for what parity cannot
cover: once the fragments sent after a gap have arrived, as many data fragments as the block
would still lack if every fragment not yet known lost arrived.

### Implementation defaults

None of these is on the wire.

| | |
|---|---|
| Latency budget | `max(50 ms, 2 × srtt + 20 ms)`, at most 150 ms (the `DESKTOP` formula in [modes.md](../docs/modes.md)). Both ends take a first round-trip sample from the handshake: the client from INIT to RESPONSE, the host from RESPONSE to the `PING` the client sends on opening it |
| Late is not lost | With nothing heard for 30 ms the link counts as silent, and the client gives up on no frame. When it hears again after a silence, open frames on the client and stored frames on the host get the silence back, up to 400 ms per frame in all. A Wi-Fi stall (AWDL) then costs its own length, with no keyframe |
| After a burst | every frame is decoded, but only the newest of those waiting is shown |
| Feedback | every 20 ms while packets that need reporting arrive, every 200 ms otherwise; acknowledgements within 2 ms |
| Keepalive | `PING` after 250 ms without sending |
| Client silent | host stops media after 2 s, keeping capture and the encoders warm; resumes with a keyframe on each stream at the next packet; forgets the session after 60 s |
| Host silent | client starts a new handshake after 5 s |
| Reliable input queue full | pending pointer motion is retained and coalesced; a refused key, button, or scroll ends the session and reports the reason, so CLOSE, a replacement handshake, or host silence resets held input |
| Sessions | one at a time; a new handshake replaces the current session |
| Pacing | each video stream paces itself: it drains its backlog within a frame interval of its last frame, at least 1.25 × the bitrate, in bursts of 32 datagrams; the order the streams drain in rotates |

## Layout

| Target | What it is |
|---|---|
| `LightrayCore` | The protocol, with no I/O and nothing platform-specific beyond CryptoKit, so that an iPad client can reuse it. The endpoints take datagrams and the time, and return datagrams and events |
| `LightrayMac` | The UDP socket, the HID ↔ Mac key-code map, pairing storage, and the VideoToolbox encoder and decoder |
| `lightray-host` | The display list, a capture-and-encode pipeline per video stream, and CGEvent injection |
| `lightray-client` | A window per video stream: decoding into an `AVSampleBufferDisplayLayer`, keyboard and mouse capture, and the Displays menu |

Each executable runs its endpoint, socket and timer on one serial queue. Each video stream has a
queue of its own: for capture and encoding on the host, and for decoding on the client.

## Not yet

- Audio and the microphone.
- `PARK` and `RESUME`, and taking over a session after the client restarts
  (`RESUME_SESSION_ID`). The host's pause on silence is the nearest thing.
- Long-term-reference recovery (version 1 adds a reference epoch first). Recovery is parity,
  retransmission, then an IDR.
- FEC that adapts to the loss it sees: the percentage is fixed, as in Sunshine.
- Rate control: the bitrate is fixed, for each stream.
- `SETTINGS` and control messages other than choosing displays: the host's options set the
  streams, the same for all.
- The cursor channel, relative pointer motion, gamepads and text input.
- Capturing system shortcuts on the client.

Windows hosts can now report capture/convert and encode durations in the HUD; see [host telemetry semantics and validation](../docs/windows/host-telemetry-progress.md).

## Session controls and host preferences

The client exposes a Lightray session button in windowed and full-screen mode, also available through View → Session Menu or Control+Option+Command+S.
Opening it releases remote input; closing it keeps input released until explicit resume or a consumed click on the video.
The panel offers statistics, optional Command/Control swapping, local pointer, full screen, Alt+Tab, Windows key and preference reset.
Remote actions require live decoded video; waiting or interrupted video cannot forward input.
The cursor remains visible locally while input cannot be forwarded.

Preferences persist by public pairing ID and contain no pairing key or clipboard data.
Explicit CLI choices override the initial saved values without saving them at launch: `--stats`/`--no-stats`, `--physical-keys`/`--swap-command-control`, and `--host-cursor`/`--local-cursor`.
Use `--no-preferences` to isolate a lab run and `--screen-id N` to select a local presentation monitor after checking the current screen inventory.
Successful decodes drive a local waiting/live/interrupted state; two seconds without progress after live video pause input, without attributing the cause to capture or network.
See [implementation, evidence and remaining validation](../docs/windows/session-controls-progress.md).
