# LightrayCore

The Swift package the Lightray apps share on macOS and iOS: the protocol in
[`docs/`](../../docs/README.md), and what an app needs around it to run a host or a client.

- **The protocol**, with no I/O: the handshake, packets, reliable streams, video with FEC, and the
  host and client endpoints. An endpoint takes datagrams and the time, and returns datagrams and
  events.
- **Around it:**
  - the UDP socket and the clock;
  - pairing tokens and their storage, saved computers and per-host session preferences;
  - the HID ↔ Mac key-code map, and the remote keyboard, which can swap Command and Control for
    Windows hosts;
  - the VideoToolbox encoder, and a bounded decoder that drops what it cannot keep up with and
    measures its timings;
  - `VideoRenderer`, which shows decoded pictures in an `AVSampleBufferDisplayLayer`;
  - `ClientRunner`, which runs a client's endpoint and decoders on queues of their own and leaves
    the app its windows and input.

The Mac host and client are in [`mac-client/`](../mac-client/README.md) and [`mac-host/`](../mac-host/README.md), and the iPad client is in
[`ios-client/`](../ios-client/README.md). Each app depends on this package by its sibling path.

## Build and test

Requires macOS 27 or iOS 27, and Swift 6.4. The package builds in the Swift 6 language mode.

```bash
swift test --package-path apple/core
```

The tests reproduce every value in [`tools/vectors/vectors.json`](../../tools/vectors/vectors.json),
parse and re-encode the hex examples in the version 0 documents, decode the IDR published in
[`video.md`](../../docs/video.md) with VideoToolbox, and run a host against a client over a simulated
path with loss, jitter and address changes. The names of the conformance tests they cover are in
the test files.

For iOS, from this directory:

```bash
xcodebuild -scheme LightrayCore -destination 'generic/platform=iOS' build
```

In the iOS Simulator every test passes except `encoderOutputDecodes`: the simulator has no
hardware HEVC encoder.

## What is implemented

| Document | State of the document | Here |
|---|---|---|
| [handshake.md](../../docs/handshake.md) | Version 1 | All of it except taking over a session: `NNpsk0`, the padded INIT with don't-fragment, the INIT cache answered with the identical RESPONSE, the timestamp window, retransmission, the 64-packet early buffer, `SESSION_UNKNOWN` with its rate limit and constant-time check |
| [packets.md](../../docs/packets.md) | Version 1 | All of it: sealing, packet-number reconstruction, the 2048 replay window, chunk parsing with must-ignore and contained errors, stream direction and class checks, rebinding on the strictly newest packet, the 3× cap on a new IP address until a `FEEDBACK` validates it |
| [video.md](../../docs/video.md) | Version 0 text, FEC as version 1 plans it | The frame header with `CODEC_CONFIG`, fragmentation at `stride = mds − 51`, reassembly with its bounds, ordered delivery behind the `PREVIOUS` gate, the retransmission store, pacing, and IDR recovery. FEC scheme 1, per-frame Reed–Solomon after RFC 5510, in a [provisional](#provisional-fec-format) form; recovery in the order FEC, retransmission, IDR. No long-term references |
| [feedback.md](../../docs/feedback.md) | Version 0 text | `FEEDBACK` with RTT from the hold time, `NACK` for what parity cannot cover, `REFRESH_REQUEST` attempts, `PING`/`PONG`. A tail counts as lost once a later frame arrives, with the tail timeout only as a fallback. No loss backstop |
| [input.md](../../docs/input.md) | Version 0 text | `RELIABLE` streams with acknowledgements in `FEEDBACK`; one stream per device; pointer motion merged at 1 ms. The payloads are [provisional](#provisional-input-format) |
| [displays.md](../../docs/displays.md) | Version 1, byte layouts pending | Several video streams, each independent; the display list; binding a stream to a display, two streams to one display, and the host binding its primary display to the first stream; pointer positions naming a display; hot-plug and mode changes. The messages are [provisional](#provisional-control-messages). Not yet: bindings in the INIT, weights, per-stream settings other than the display |

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
| `0x02` `TEXT` | `length:u16, utf8:length bytes` | Committed text on the keyboard stream, independent of the host keyboard layout. Length is 1–1024 bytes; invalid UTF-8 is rejected. The Mac host injects Unicode keyboard events. Older hosts ignore this message |
| `0x10` `POINTER` | `x:u16, y:u16, display:u32` | Position on the host's display `display`: 0 is its left or top edge, 65535 its right or bottom. A `display` of 0, or none, means the primary display; an unknown one is ignored |
| `0x11` `BUTTON` | `button:u8, down:u8` | 1 left, 2 right, 3 middle, 4 back, 5 forward |
| `0x12` `SCROLL` | `dx:i16, dy:i16, units:u8` | Units: 0 is 1/120 of a wheel notch, 1 is pixels. Positive `dy` scrolls up, as the client's Mac reports it after its own natural-scrolling setting; the host posts it unchanged |

A receiver ignores a message of unknown type, and bytes after the fields it knows. Caps Lock is
sent as a press and release per toggle, and the host keeps the lock state.

### Provisional control messages

[displays.md](../../docs/displays.md) defines what these mean; control.md will give them their bytes
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
bytes. Until [video.md](../../docs/video.md) does, this implementation uses the following, which
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

### Provisional host timing extension

The Windows laboratory host in [`tools/windows`](../../tools/windows/README.md) can report how long
it took to capture and encode each frame, for the client's statistics overlay. It does so with
frame-header extension type `0xF0`, which must be coordinated before it becomes a protocol
assignment. The Mac host does not send it.

- **Value**, 17 bytes, big-endian: `version:u8` = 1, `capture_duration_us:u32`,
  `encode_duration_us:u32`, `host_sample_id:u64`. With its header the extension adds 20 bytes to
  a frame, and the host leaves it out when it would overflow the extension area's `u16` length.
- **Durations** are on the host's monotonic clock, at most 1,000,000 µs each, with no clock
  synchronization assumed. The sample ID counts the host's frame attempts in its current process
  and can have gaps; it is diagnostic, not a frame ID.
- **Receiving.** An unknown version, a value of another size, a duration out of range or a second
  timing extension makes the timing unavailable without invalidating the frame; malformed
  extension framing still invalidates it. Absence means unavailable, never zero. Receivers
  without this extension skip it as any unknown extension.
- **What the overlay shows.** It averages the samples of the frames decoded in the current epoch
  over about a second, apart from the client's own decode and queue times. Lost, undecodable and
  dropped frames are not counted, and the round-trip time is not added to them: none of it is
  input-to-photon latency.

### Pairing invite

Pairing is the application's to define ([gaps.md](../../docs/gaps.md#pairing)). Lightray Host
shows a QR code when it adds a device, and the iPad's scanner reads it as a `PairingInvite`:

```
lightray://pair?address=HOST&name=NAME&code=lr1-…
```

- **`address`**: where to reach the host, `hostname:port` as the client's address field takes it.
  Required, at most 255 characters, no whitespace.
- **`name`**: the host's computer name, at most 100 characters; may be absent.
- **`code`**: the device's pairing token, `lr1-` then the identifier and key in hex.
- Values are percent-encoded except unreserved characters. A repeated parameter, a control
  character, or more than 1 KiB in all is refused; unknown parameters are ignored.
- No app registers the `lightray` scheme, so the system never hands an invite to another app.

### Implementation defaults

None of these is on the wire.

| | |
|---|---|
| Latency budget | `max(50 ms, 2 × srtt + 20 ms)`, at most 150 ms (the `DESKTOP` formula in [modes.md](../../docs/modes.md)). Both ends take a first round-trip sample from the handshake: the client from INIT to RESPONSE, the host from RESPONSE to the `PING` the client sends on opening it |
| Late is not lost | With nothing heard for 30 ms the link counts as silent, and the client gives up on no frame. When it hears again after a silence, open frames on the client and stored frames on the host get the silence back, up to 400 ms per frame in all. A Wi-Fi stall (AWDL) then costs its own length, with no keyframe |
| After a burst | every frame is decoded, but only the newest of those waiting is shown |
| Feedback | every 20 ms while packets that need reporting arrive, every 200 ms otherwise; acknowledgements within 2 ms |
| Keepalive | `PING` after 250 ms without sending |
| Client silent | host stops media after 2 s, keeping capture and the encoders warm; resumes with a keyframe on each stream at the next packet; forgets the session after 60 s |
| Host silent | client starts a new handshake after 5 s |
| Reliable input queue full | pending pointer motion is retained and coalesced; a refused key, button, or scroll ends the session and reports the reason, so CLOSE, a replacement handshake, or host silence resets held input |
| Sessions | one at a time; a new handshake replaces the current session |
| Pacing | each video stream paces itself: it drains its backlog within a frame interval of its last frame, at least 1.25 × the bitrate, in bursts of 32 datagrams; the order the streams drain in rotates |

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
- The cursor channel, relative pointer motion and gamepads.
- Capturing system shortcuts on the client.
