# Lightray — Protocol v0 implementation plan

## Context

`/Users/diogoviannaaraujo/Projects/lightray` holds this plan and the Phase 0 spikes (Swift 6.2, Xcode 26.0). We are building a custom, GameStream-inspired UDP streaming protocol as a Swift library for Apple platforms, macOS first. It is protocol-only: no encoders or decoders, and no input capture. The priorities are:

1. Reconnect: park, rebind, then resume on an IDR.
2. Loss recovery: NACK first, then LTR, then IDR. FEC is reserved.
3. A wire format that already carries what a future congestion controller or FEC scheme needs.
4. Instrumentation from day one.

Confirmed decisions:
- **Keys:** an in-band 1-RTT handshake using an app-supplied pairing PSK plus X25519 ephemeral keys.
- **Roles:** host and client share a symmetric core, and both roles ship.
- **Codecs:** pinned to the wire version. v0 is H.265 (HEVC) for video and Opus for audio at 48 kHz with 20 ms frames. There is no codec negotiation and no mid-session codec change. The library still holds no encoders or decoders; payloads stay opaque bytes.
- **Platforms:** macOS → macOS first, then macOS → Windows, then iOS. v0 is macOS-only, and all code, tests and benchmarks target macOS.
- **Portability:** this package is Apple-only for its whole life, so it calls CryptoKit, kqueue and `Network` directly with no abstraction for other platforms. A Windows client is a separate implementation against the wire format, which makes `Docs/protocol-v0.md` and its golden vectors normative: anything a receiver must do to be correct belongs in the spec, not only in a Swift type.
- **Layout:** one SwiftPM package with many focused modules.
- **Minimum OS:** macOS 26, so `Span`/`RawSpan`/`InlineArray`/`Mutex`/`Atomic` are all usable.
- **Dependencies:** none in the library. The only dependency is `package-benchmark`, confined to `Benchmarks/`.

## Architecture

**Sans-IO core.** Every protocol state machine is a synchronous, non-Sendable type with no sockets, threads or clocks inside it. Each one takes these inputs:
- `handle(datagram:from:at:)`
- `handleTimeout(at:)`
- app commands

and produces these outputs:
- `pollTransmit(into:)`
- `pollEvent()`
- `nextTimeout()`

This makes the core deterministic and testable on a virtual clock, and lets benchmarks run without sockets. A thin Darwin runtime drives each engine on one dedicated thread.

### Modules (one package, each is its own library product)

| Module | Depends on | Contents |
|---|---|---|
| `LightrayPrimitives` | — | `Instant`/`Duration` (UInt64 ns, suspending monotonic: it does not advance across system sleep), `MonotonicClock` protocol, `RawSpan` read cursor and bounded byte writer, `BufferPool` (fixed MTU slabs + size-classed large frame buffers), `SerialNumber` (wrap-safe u32 compare), ring buffer, `InlineArray` bitsets. No Foundation. |
| `LightrayWire` | Primitives | Stateless codecs: handshake packets, protected header, all chunk types, frame header, TLV codec (capabilities/RECONFIGURE), FEC ext TLV. Must-ignore for unknown chunks/TLVs. No Foundation. |
| `LightrayStats` | Primitives | `PathStats`, `StreamStats`, `ReconnectStats`, log2 histograms (`InlineArray`), EWMA/jitter/OWD-queuing estimators, `LinkQuality` summary, `EventLog` ring (park/resume/rebind/refresh timeline). All allocation-free updates. |
| `LightrayCrypto` | Primitives, Wire, CryptoKit | Handshake initiator/responder state machines, key schedule (HKDF-SHA256), `PacketProtection` protocol + `AESGCMProtection`, packet-number reconstruction, 2048-bit replay window, stateless-reset token. |
| `LightrayStreams` | Primitives, Wire, Stats | Per-stream machinery: `Fragmenter`, `Reassembler`, `NackScheduler` + `NackPolicy`, `RetransmitStore`, `ReliableChannel`, `DecodabilityTracker` (LTR/IDR gating), `SentPacketLog`, `Pacer` + `PacingPolicy`, `BitrateController` (manual + loss backstop), `FECScheme` (`NoFEC`). |
| `LightraySession` | all above | `Connection` engine (shared by both roles): handshake, stream multiplexing, feedback, keepalive/RTT, reconfigure, recovery requests, park/rebind/resume. `HostEndpoint` (demuxes many sessions by `session_id`, parking and grace windows, stateless reset) and `ClientEndpoint` (resume, socket-replacement semantics). Platform seams: `DecoderHost`, `AudioSink`, `DisplayClock`. |
| `LightrayTransport` | Session, Darwin, Network | `UDPSocket` (non-blocking, dual-stack, don't-fragment set so the padded INIT proves path MTU, large socket buffers, QoS marking where the platform honours it), one kqueue `EventLoop` thread (socket readability, cross-thread commands, and timers precise enough for 1 ms pacer ticks), and the public `LightrayHost`/`LightrayClient` runtimes. `NWPathMonitor` triggers proactive socket replacement on the client. Which sockopts and timer flags actually deliver this, including the ones that do not behave as documented, is in `Spikes/FINDINGS.md`. |
| `Lightray` | Session, Transport | Umbrella that re-exports the public API. |
| `LightrayDebugOverlay` | Stats, SwiftUI | macOS SwiftUI stats overlay + `LinkQualityIndicator` (loss, RTT, queuing delay, backstop state, reconnect timeline). |
| `LightrayTestSupport` | Session, Primitives | `ManualClock`, `SimulatedNetwork` (discrete-event, seeded), fake seams, synthetic frame source. |
| `lightray-demo` (executable) | Lightray | macOS CLI `host`/`client` over real UDP with synthetic frames and a live stats printout, for manual reconnect testing. |

Rules that keep the core fast:
- Hot-path helpers (cursors, header codec, serial math) are `@inlinable`.
- Generics are used instead of existentials on per-packet paths. Existentials are only allowed per frame or per event, e.g. seam calls.
- Wire, Streams and Stats must do zero allocations per packet in steady state.

### Deferred items behind seams (v0 implementation in parentheses)

- `CongestionController`/`BitrateController` (manual + backstop).
- `PacingPolicy` (frame-spreading token bucket).
- `FECScheme` (`NoFEC`).
- `NackPolicy` (default timers).
- `DatagramSocket` + `PeerAddress` (no WAN traversal).
- `PacketProtection` (AES-GCM; a plaintext protector exists only in TestSupport for isolating benchmarks).

## Wire format v0 (the full spec goes in `Docs/protocol-v0.md` with golden vectors)

All integers are big-endian. `max_datagram_size` = UDP payload, default 1200, configurable and negotiated.

The version byte pins the codecs: v0 means H.265 (HEVC) video and Opus audio on every media stream. Audio is fixed at 48 kHz with 20 ms frames and is decoded as stereo, with mic streams mono. An Opus packet's TOC byte already describes its own framing and channel mode, and a mono stream decodes to stereo, so no audio configuration needs to be carried or negotiated. Nothing on the wire carries a codec identifier, and a different codec means a different wire version, so a peer that disagrees about codecs fails the version check instead of negotiating.

**Handshake packets** (the first byte has its high bit set):
- **`INIT` (0x80), client → host:**
  - `version:u8`, `reserved:u16`, `pairing_id:u64`, `client_ephemeral[32]`
  - An AEAD-sealed TLV body: capabilities, stream table, initial config, `max_datagram_size`, client timestamp (replay guard), optional `resume_session_id`.
  - Padded to `max_datagram_size`, which both limits amplification and proves the path MTU.
- **`RESPONSE` (0x81), host → client:**
  - `version`, `session_id:u32`, `host_ephemeral[32]`
  - A sealed body: accepted capabilities (`LTR`, `INTRA_REFRESH` = reserved/never accepted in v0, `FEC` = [NONE]), stream table, `pipelineIdleAfter` and `graceWindow`, stateless-reset token.
- **`SESSION_UNKNOWN` (0x82):**
  - `session_id` + a 16-byte token (an HMAC of the host secret and `session_id`).
  - Lets a client learn at once that its session expired. It is rate-limited and always smaller than the packet that triggered it.
- **Version mismatch:** the host drops the packet silently and bumps a counter.
- **Keys:** a Noise NNpsk0-shaped schedule. PSK, both ephemerals and DH(e_c, e_h) feed HKDF over a transcript hash, which yields separate AES-128-GCM key/IV pairs per direction.
- **Nonce:** the IV XORed with the full 64-bit packet number.

**Protected packet header** (16 bytes, cleartext, authenticated as AAD):

| Offset | Field | Contents |
|---|---|---|
| 0 | `flags:u8` | bit7 = 0 (short form), bit6 = `key_phase` (reserved), rest reserved/ignored |
| 1 | `reserved[3]` | for CC/FEC signalling without a version bump |
| 4 | `session_id:u32` | |
| 8 | `transport_seq:u32` | low 32 bits of a per-direction u64 counter; increments on every datagram, retransmits included; the receiver reconstructs the full 64 bits |
| 12 | `send_time_us:u32` | sender's monotonic clock; only deltas are used |

The header is followed by an encrypted chunk sequence, then a 16-byte tag. Each chunk is `type:u8, length:u16, body`, and unknown types are skipped.

| Chunk | Body |
|---|---|
| `MEDIA_FRAGMENT` 0x01 | `stream:u8, flags:u8 (keyframe, retransmission, …), frame_id:u32, fragment_index:u16, fragment_count:u16, stride:u16, ext_len:u8, ext TLVs`, then payload. v0 always writes the FEC TLV `{type 0x01, len 1, scheme NONE}`. Every non-last fragment of a frame carries exactly `stride` payload bytes, so the receiver places any fragment at `index × stride` straight into one contiguous buffer — including a last fragment that arrives before any other, and after a mid-session `MAX_DATAGRAM_SIZE` change. |
| `RELIABLE` 0x02 | `stream:u8, msg_seq:u32, seg_index:u16, seg_count:u16`, payload. Ordered, acknowledged via FEEDBACK, with RTO. Stream 0 is the control channel. |
| `DATAGRAM` 0x03 | `stream:u8`, payload (unreliable). |
| `FEEDBACK` 0x10 | `base_seq:u32, count:u16, base_arrival_us:u32`, a received bitmap, then an `i16` arrival delta per received packet in 4 µs units. RTT comes from the feedback header's `send_time` minus the last arrival (the hold time), with no PING needed. |
| `NACK` 0x11 | `stream:u8`, entries of `(frame_id:u32, first:u16, count:u16)`; `count = 0` means the whole frame (fragment count unknown). |
| `FRAME_ACK` 0x12 | Entries of `(stream:u8, frame_id:u32, status: received\|decoded)`. `decoded` on an LTR-marked frame is the LTR ack. |
| `REFRESH_REQUEST` 0x13 | `stream, reason (loss\|decoder_reset\|resume), preferred (ltr\|idr), last_good_frame, lost_frame, req_id`. Repeated until a recovery frame arrives. |
| `PING`/`PONG` 0x30/0x31 | Idle keepalive + RTT. |
| `PARK` 0x32 | Best-effort notice that the client is going idle. |
| `RESUME` 0x33 | `flags (decoder_lost)`. Repeated until STATE arrives. |
| `CLOSE` 0x34 | `code:u16`. |

**Control messages** on reliable stream 0:
- `RECONFIGURE {req_id, scope_stream, TLVs: BITRATE, BITRATE_FLOOR, RESOLUTION, FRAMERATE, HDR, MAX_DATAGRAM_SIZE}`. This is one path for every parameter; manual bitrate changes ride it. There is no codec TLV, because the codec is fixed by the wire version.
- `RECONFIGURE_RESULT` (the values actually applied, or rejected).
- `STATE` (a full snapshot of the current configuration, with flags `resume|backstop`).

**Frame header:** the sender logically prepends it to each frame's bytes, so fragmentation stays payload-agnostic and zero-copy. It carries:
- `frame_type` (idr/predicted/…)
- `ref_kind` (none/previous/ltr/ltrAny) + `ref_frame_id`, which is present for `ltr` and absent for `ltrAny`
- `ltr_mark`
- `config_generation`
- `capture_time_us`
- ext TLVs: `CODEC_CONFIG` on every IDR; an intra-refresh-complete flag is reserved here.

HEVC parameter sets (VPS, SPS and PPS — 81 bytes on the encoders measured, 4-byte NAL length) are **not** in-band in slice data, and no decoder can be constructed without them, so every IDR carries them in its own `CODEC_CONFIG` TLV. They change only with resolution or profile, and both of those force an IDR, so the set a receiver needs is always attached to the frame that needs it: a joining or rebuilt decoder never waits on a separate message, and a `decoder_lost` resume needs nothing beyond the recovery IDR itself.

`frame_id` is assigned by the protocol when a frame is submitted, and only for frames that produced bytes. A low-latency encoder under a tight budget skips frames outright and emits nothing at all for them, so an id assigned per capture would leave gaps indistinguishable from whole-frame loss. Capture cadence remains visible through `capture_time_us`.

**Payload budget at 1200 bytes:**
- Overhead: 16 header + 16 tag + 3 chunk header + 13 fragment header + 3 FEC TLV = 51 bytes.
- 1200 − 51 = 1149 payload bytes per fragment (96%).

## Key mechanisms

**Reconnect (the priority path)**

- **Host parking:**
  - The host parks a session when it receives a PARK, or after `parkAfterSilence` (default 2 s; the client keeps the link warm with FEEDBACK or 250 ms PINGs).
  - Parking immediately releases the retransmit store, pacer queues, reassembly state and LTR ack state. None of it can reach an absent peer, and a resume forces an IDR that would discard it anyway. What remains — keys, packet-number and replay state, the stream table, the config snapshot, rebind state and stats — is under 1 KB plus a few KB of stats, and costs no processing: nothing is sent to a parked session, no per-session timer runs, and expiry is one coarse sweep over the parked set.
  - While parked, the host emits `.parked` so the app pauses its encoder and capture but keeps them alive.
  - After `pipelineIdleAfter` (default 60 s) the host emits `.idle` and the app tears the encoder and capture down. The session is untouched, so a client returning later still resumes; it needs a fresh encoder only because a resume forces an IDR regardless. The paused pipeline is the only expensive thing a park holds, which is why this threshold is separate from the next.
  - `graceWindow` (default 30 min, in host-running time) ends the session: the host emits `.expired` and discards it with its keys. A window this long is affordable only because parking released the media buffers. `maxParkedSessions` bounds the table, evicting the oldest parked session first, and parked sessions are discarded on system sleep.
- **Rebind rule:**
  - A packet from a new address rebinds the session only if all three hold: it authenticates, it passes the replay window, and its `transport_seq` is higher than any seen before.
  - If the session was not parked, rebinding happens silently, with no IDR (NAT rebinding or Wi-Fi roaming).
- **Resume from parked:**
  1. Flush pacer queues, NACK and reassembly state in both directions; the host released its media buffers back at the park.
  2. Send `STATE` reliably.
  3. Emit `.resumed` and `.refreshRequired(stream, .idr)` for every outbound video stream. A resume is always an IDR.
- **Client side:**
  - App-driven commands: `park()` sends PARK, and `resume(decoderLost:)` recreates the socket (new port) and sends RESUME. The app decides what counts as going idle — on macOS, screen lock or the user stepping away from the stream.
  - System sleep is not a park. A lid close ends the session: the client sends CLOSE if it still can and re-handshakes on wake rather than resuming across the sleep, which costs one round trip and an IDR with no re-pairing. This is why `Instant` need not advance across sleep, and why no keys sit in a hibernation image.
  - The client also recreates its socket and resumes on socket errors and on `NWPathMonitor` path changes.
  - RESUME is repeated with backoff. A valid `SESSION_UNKNOWN` produces `.sessionLost` immediately, and the app re-handshakes.
  - The re-handshake may carry `resume_session_id`. If the host still has that session parked under the same pairing, it adopts it with new keys.

**Recovery**

1. **NACK:**
   - Gaps are detected from fragment indices within a frame, `frame_id` gaps (whole-frame NACKs) and tail-loss timers.
   - Default `NackPolicy`: first NACK after the reorder window (≥ 1 ms), retry every `max(1.5·srtt, 2 ms)`, give up at the frame deadline (default 3 frame intervals).
   - The sender retransmits from `RetransmitStore` (500 ms / 16 MB cap), deduplicated within srtt/2. Each retransmit gets a new `transport_seq` and a retransmission flag, and is prioritized ahead of new data.
2. **LTR:**
   - The encoder marks every frame as an LTR candidate, so the receiver picks the ack points: it acks at most one LTR-marked frame per `ltrAckInterval` (default 250 ms), once `DecoderHost` reports it decoded. The sender retains the last `maxAckedLTR` acks (default 16), which bounds both the acked set and FRAME_ACK traffic.
   - When a frame is lost with the decoder still alive, the receiver sends `REFRESH_REQUEST`. If LTR was negotiated and an ack exists, the sender offers the encoder its whole retained set and emits `.refreshRequired(.ltrAny)`; otherwise `.idr`. The encoder chooses the reference and does not report the choice, so the refresh frame is marked `ref_kind = ltrAny`, which the receiver accepts unconditionally — sound because it only ever acks frames it decoded.
   - `DecodabilityTracker` keeps undecodable frames away from the decoder until an IDR arrives, or a frame that references an acked LTR. A config flag forces IDR-only, and tests exercise that fallback.
3. **FEC:** `NoFEC` is plumbed through both the send and receive paths; the TLV is present but empty.

**Bitrate v0**

- The client sets bitrate manually through `RECONFIGURE`. There is no automatic control loop.
- `Pacer`: a token bucket at `max(pacingGain × targetBitrate, frameBytes / spreadTarget)`, capped by `linkRateCeiling` with a `maxBurstBytes` limit. This spreads a 500 KB IDR across the frame interval instead of dumping it all at once. Priority order: control > retransmissions > audio > video.
- `BitrateController` backstop:
  - The sender measures transport loss from FEEDBACK over 500 ms windows.
  - If loss stays above the threshold (default 10%) for N windows (default 4), it clamps the bitrate to the floor, emits `.bitrateChanged(reason: .lossBackstop)` and sends `STATE{backstop}` so the client UI can show it.
  - There is no automatic ramp-up; only a manual RECONFIGURE raises the bitrate again.

**Instrumentation**

- Stats are updated inline on every sent and received packet:
  - arrival times, jitter, sequence gaps, reorder and duplicates
  - relative one-way delay, used to estimate queuing delay
  - srtt/rttvar
  - frame completion latency histogram
  - pacer queue depth, bytes and age
  - reassembly in flight and decode queue depth
  - NACK and retransmit counts
  - resume latency
- `SentPacketLog` (indexed by transport_seq) is where a future congestion controller will plug in.
- The runtime publishes a `StatsSnapshot` to `Mutex` + `AsyncStream` at ≤ 10 Hz, which feeds the overlay and indicator.

**Stream model**

Streams are negotiated in the handshake table as `{id:u8, kind: video|audio|input|mic|camera|data, direction, class}`. The codec follows from the kind and the wire version, so there is no per-stream codec tag and no per-stream codec parameters: video resolution and frame rate ride RECONFIGURE, and the audio configuration is fixed by the version. There are four classes:
- `media`: fragmented, NACK, deadline, decodability gating.
- `realtime`: small frames; NACK within the deadline; gaps are reported to `AudioSink` for packet-loss concealment.
- `reliable`: ordered.
- `unreliable`.

Mic and camera use the same machinery in the reverse direction.

**Seams** (defined in `LightraySession`, implemented by apps; test fakes live in TestSupport):
- `DecoderHost` receives a pooled `ReceivedFrame` (zero-copy `RawSpan` payload) on the loop thread. It reports `decoded`, `failed` or `invalidated` asynchronously through a `DecoderReporter`.
- `AudioSink` receives opaque codec packets with timestamps and gap markers, and optionally reports its buffer level.
- `DisplayClock` provides the refresh interval and the next present time, used for frame→display latency stats.
- On the sending side, the app submits `EncodedFrame(stream, storage: some ByteStorage, info)`. The storage is retained, not copied, until it leaves the retransmit window.

## Repository layout

```
Package.swift                 // tools 6.2, Swift 6 mode, platforms .macOS(.v26), ExistentialAny
Sources/<one dir per module above>, Sources/LightrayDemo
Tests/<Module>Tests (Swift Testing), Tests/LightrayScenarioTests (SimulatedNetwork end-to-end)
Benchmarks/Package.swift      // package-benchmark, path-depends on ../
Docs/protocol-v0.md, Docs/architecture.md
scripts/ci.sh                 // swift build/test on macOS, benchmark smoke run
```

## Implementation phases (each ends green on macOS)

0. **Scaffold and spikes.** The spikes are done. `Spikes/FINDINGS.md` records the results and is the source for every measured number quoted in this plan: Spike 1 (a `~Escapable` RawSpan cursor, with `(RawSpan, inout offset)` as the fallback), Spike 2 (CryptoKit AES-GCM cost and allocations per 1200-byte packet), Spike 3 (kqueue timer precision), plus the socket, throughput, VideoToolbox and codec probes that the later phases rely on.
   - Still to do: `git init`, `Package.swift`, empty modules, `scripts/ci.sh` and a `.gitignore`.
1. **Primitives + Wire.**
   - All codecs, `Docs/protocol-v0.md` (normative, and written to be implementable without reading the Swift), golden byte vectors as data files a non-Swift implementation can consume, round-trip tests, and a fuzz test that mutates or truncates datagrams and asserts no crash or overread.
   - First benchmarks: header and fragment encode/decode.
2. **Stats + Streams.**
   - Fragmenter/Reassembler (including out-of-order arrival, last fragment first, whole-frame NACK), NackScheduler, RetransmitStore, ReliableChannel, DecodabilityTracker, Pacer, BitrateController.
   - Unit tests plus benchmarks: 500 KB IDR fragment and reassemble, NACK under 1% loss.
3. **Crypto.**
   - Handshake, key schedule, protection, replay window, reset token.
   - Tests: version mismatch → dropped, wrong PSK → dropped, tampered header or payload → dropped, replay → dropped, old-seq packet from a new address → no rebind, nonce uniqueness.
   - Benchmark: seal/open packets per second.
4. **Session + TestSupport.**
   - The `Connection`/`HostEndpoint`/`ClientEndpoint` engines, `SimulatedNetwork` with these link models: Bernoulli and Gilbert–Elliott loss, delay and jitter, reorder, bottleneck rate + drop-tail queue, address change, blackout.
   - The scenario suite below.
5. **Transport runtime.**
   - UDPSocket, EventLoop, `LightrayHost`/`LightrayClient`, the park/resume commands, path monitor, and `lightray-demo`.
   - Loopback tests over 127.0.0.1, including forcing a new client port mid-stream.
6. **Overlay + benchmark baselines.**
   - `LightrayDebugOverlay`, full-pipeline benchmarks, recorded thresholds, and `Docs/architecture.md`.

## Verification

**Scenario tests** (`LightrayScenarioTests`, deterministic, virtual time):
- 60 s of 1080p60 at 20 Mbps on a clean link: every frame completes and no NACKs are sent.
- 2% random loss at 4 ms RTT: ≥ 99.9% of frames complete by the deadline, and none reach the decoder undecodable.
- 30 ms burst loss:
  - with LTR negotiated, `.refreshRequired(.ltrAny)`, and the refresh frame is accepted without an IDR;
  - without it, `.idr`.
- A frame the encoder skipped: no whole-frame NACK is sent, because no id was ever assigned.
- A receiver joining at an IDR builds its decoder from that frame's own `CODEC_CONFIG`, with no prior session state.
- A 60 s session at 60 fps: the acked-LTR set never exceeds `maxAckedLTR`, and FRAME_ACK volume tracks `ltrAckInterval` rather than the frame rate.
- 20 s of client absence, inside `pipelineIdleAfter` so the pipeline is still warm (PARK, blackout, new source port): the host parks, then resumes on the first authenticated packet. Stale frames are flushed, STATE is received and the first delivered frame is an IDR. Resume→first-frame latency is recorded.
- Silent disappearance: the host parks after the timeout and releases its media buffers, emits `.idle` at `pipelineIdleAfter`, then `.expired` when the grace window runs out. A client returning between the two still resumes; one returning after gets `SESSION_UNKNOWN`, emits `.sessionLost` and re-handshakes. Parked footprint is asserted to stay under 1 KB plus stats for the whole window.
- NAT rebinding mid-stream: the stream continues with no IDR.
- A 30 Mbps bottleneck with the bitrate set to 50 Mbps: queuing delay visibly rises in the stats, the backstop engages at the floor, and the client receives `STATE{backstop}`.
- A 500 KB IDR through the pacer: the bottleneck queue peak is bounded, compared against an unpaced baseline.
- A RECONFIGURE round trip: the result matches what was applied, and `config_generation` bumps.
- Bidirectional traffic (host video + audio; client mic + camera + reliable input at 5% loss): the input arrives complete and in order.

**Commands:**

```bash
swift build && swift test
```

```bash
cd Benchmarks && swift package benchmark
```

**Benchmark targets** (Phase 0 baselines are in `Spikes/FINDINGS.md`; these become recorded thresholds in Phase 6):
- Zero allocations per packet in steady state across Wire, Streams and Stats. Crypto is excluded, because AES-GCM through system APIs has no in-place form and always allocates.
- The receive path, excluding crypto, under 250 ns per packet.
- Full sans-IO pipeline cost per frame reported at 1080p60/20 Mbps and 4K60/80 Mbps. 60 fps is the ceiling; nothing above it is a target.
- Loopback UDP with crypto sustains ≥ 1 Gbps on a single loop thread — headroom over the working range, not a working point.

**Manual check:** run `lightray-demo host` and `lightray-demo client`. Kill the client's network or restart it with a new port inside the grace window, and watch the overlay and stats timeline show park → resume → IDR.

## Out of scope for v0

- Any platform but macOS. Windows comes after v0, iOS after that.
- Encoders and decoders, and input capture/injection.
- Pairing UX (the app supplies the PSK).
- A congestion-control algorithm and FEC schemes (seams only).
- WAN/NAT traversal.
- Intra-refresh (reserved as a capability only).
- Rekeying (the `key_phase` bit is reserved).
