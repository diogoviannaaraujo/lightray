# Lightray v0 — proof of concept

A working vertical slice of the GameStream-inspired UDP streaming protocol in
[`../Definition.md`](../Definition.md): real handshake, real crypto, real UDP,
real reconnect. macOS only; mac → mac in every test and benchmark.

It is protocol-only, as the plan requires — no encoders, no decoders, no input
capture. Media payloads are opaque bytes.

## What it does

The plan's four priorities, each verified rather than asserted:

**1. Reconnect — park, rebind, resume on an IDR.** A host parks on PARK or after
silence, releasing every media buffer while keeping keys, replay state and stats.
It goes idle at 60 s, expires at 30 minutes, and resumes on the first
authenticated packet from anywhere. A client resumes on a fresh socket; the host
sees the new source port and rebinds. NAT rebinding mid-stream continues with no
IDR. A re-handshake naming a parked session adopts it under new keys. A client
returning after the grace window gets SESSION_UNKNOWN and re-handshakes.

**2. Loss recovery — NACK, then LTR, then IDR.** A 30 ms burst at 2 ms RTT is
recovered by NACK alone: no refresh, no keyframe, no visible break. A burst past
the frame deadline produces a refresh request; with LTR the encoder is offered its
whole acked set and answers with a frame marked `ltrAny` that is accepted without
an IDR, and without LTR the answer is an IDR. Nothing undecodable ever reaches the
decoder.

**3. A wire format that already carries what comes next.** All twelve v0 chunk
types, the full handshake, the frame header with in-band `CODEC_CONFIG` on every
IDR, FEEDBACK with per-packet arrival deltas, the FEC TLV, three reserved header
bytes and a reserved `key_phase` bit. [`Docs/protocol-v0.md`](Docs/protocol-v0.md)
is normative and [`Docs/golden-vectors.json`](Docs/golden-vectors.json) is
generated from the code and compared on every test run, so a non-Swift
implementation has something to check itself against.

**4. Instrumentation from day one.** RTT, jitter, queuing delay, loss, reorder,
duplicates, gaps, NACK and retransmit counts, frame-completion histograms, pacer
queue depth, resume latency and a park/resume/rebind timeline — updated inline on
every packet, published at 10 Hz. The loop thread also reports its own CPU broken
down by phase, which is how the throughput claim above got corrected from the
syscall ceiling to what the whole stack actually costs.

## Running it

```bash
swift build && swift test
```

87 tests in 14 suites: wire round trips, golden vectors, 400,000 fuzzed datagrams,
crypto negative cases, engine units, the plan's scenario suite on a virtual clock,
and a loopback suite over real UDP.

```bash
./scripts/ci.sh
```

Everything, including the release-only allocation check and a selftest.

```bash
swift run -c release lightray-poc selftest --seconds 10
```

Both roles in one process on 127.0.0.1: stream, park, resume on a new port, and a
summary. Typical output:

```
  frames delivered      808
  keyframes delivered   2 (one at the start, one per resume)
  bytes delivered       22.8 MB
  srtt                  0.51 ms
  host rebinds          1 (the resume arrived on a new source port)
  host parks / resumes  1 / 1
  resume -> first IDR   15 ms
```

For the manual check, two terminals:

```bash
swift run -c release lightray-poc host
```

```bash
swift run -c release lightray-poc client --port <port>
```

The client takes commands on stdin: `p` park, `r` resume, `d` resume with
`decoder_lost`, `b` reconfigure to 5 Mbps, `q` quit. Both sides print a stats line
every second.

```bash
cd Benchmarks && BENCHMARK_DISABLE_JEMALLOC=true swift package benchmark
```

## Measured

Full numbers in [`Docs/benchmarks.md`](Docs/benchmarks.md). The headlines, on an
M4 in release:

| Target from the plan | Result |
|---|---|
| Receive path excluding crypto under 250 ns per packet | **33 ns** (parse plus place at `index × stride`) |
| Zero allocations per packet in Wire, Streams and Stats | **0**, counted through `malloc_logger` |
| Full pipeline per frame at 1080p60 / 20 Mbps | **212 µs**, 1.3% of a 60 fps frame budget |
| Full pipeline per frame at 4K60 / 80 Mbps | **526 µs**, 3.2% |
| Loopback UDP with crypto ≥ 1 Gbps on one thread | **2.0 Gbps** for a bare seal-and-send loop — a syscall ceiling. The whole runtime costs **13% of a core at 80 Mbps**, so its own single-thread ceiling is a few hundred Mbps |

## Layout

| Module | Contents |
|---|---|
| `LightrayCore` | `Instant`, byte cursors, `BufferPool`, `Bitset`, stats, and every wire codec. No Foundation |
| `LightrayCrypto` | handshake state machines, key schedule, packet protection, replay window |
| `LightrayEngine` | the sans-IO `Connection`, `HostEndpoint`, `ClientEndpoint` and all per-stream machinery |
| `LightrayRuntime` | the only module that touches Darwin: `UDPSocket`, the kqueue `EventLoop`, `LightrayHost`, `LightrayClient` |
| `LightrayTestSupport` | `ManualClock`, `SimulatedNetwork`, `Harness`, `DirectPair`, `SyntheticFrameSource` |
| `lightray-poc` | the demo executable |

[`Docs/architecture.md`](Docs/architecture.md) explains the sans-IO split, where
the bytes live, and which Phase 0 measurements changed the design.

## Scope: what this PoC does not cover

Deliberately out of scope, and none of it is load-bearing for what is here:

- **`LightrayDebugOverlay`.** No SwiftUI. The `StatsSnapshot` it would render is
  built and published; only the view is missing.
- **`NWPathMonitor`.** The seam is there — `LightrayClient.pathChanged()` triggers
  socket replacement and a resume, and the runtime already replaces a socket whose
  `SO_ERROR` is set — but nothing subscribes to `Network` yet.
- **FEC, congestion control, intra-refresh, rekeying.** Reserved on the wire and
  plumbed through both paths, exactly as the plan asks. `NoFEC` is the
  implementation.
- **iOS, Windows, WAN traversal, pairing UX.** v0 is macOS only.

## Where this PoC departs from `Definition.md`

Each of these is a deliberate call, and each one is either a simplification that
buys nothing to undo or a correction the tests forced.

**Simplifications.**

1. **Five library modules instead of ten.** `LightrayPrimitives`, `LightrayWire`
   and `LightrayStats` are one `LightrayCore`; `LightrayStreams` and
   `LightraySession` are one `LightrayEngine`. The dependency direction that
   matters — sans-IO core below, Darwin only at the top — is intact, and splitting
   them later is moving files.
2. **`PacketProtection` is a concrete final class with a mode switch**, not a
   generic parameter. The plan's rule is that the per-packet path carries no
   existential, and a monomorphic switch satisfies it without threading a type
   parameter through `Connection`, `HostEndpoint`, `LightrayHost` and every event
   type. The `.plaintext` mode is what lets the benchmarks separate protocol cost
   from crypto cost.
3. **`ByteWriter` is a bounded writer over `UnsafeMutableRawBufferPointer`**, not
   `OutputRawSpan`. The plan asks for "a `RawSpan` read cursor and bounded byte
   writer"; the read cursor is the `~Escapable` span cursor the plan specifies,
   and an escapable writer threads through the fragmenter without lifetime
   annotations at every layer.
4. **`Interval` rather than `Duration`**, to avoid shadowing `Swift.Duration`
   inside the module.
5. **Control chunks are never delayed by the pacer.** They spend tokens and may
   overdraw, which keeps the plan's priority order — control, retransmissions,
   audio, video — without letting an empty bucket sit on a NACK or a RESUME.

**Corrections the tests forced.** Each of these is a place where following the
plan literally produced wrong behaviour:

6. **A media fragment never shares a datagram with another chunk.** Every non-last
   fragment must carry exactly `stride` payload bytes, so piggybacking anything
   alongside would overflow the datagram. Control chunks travel in their own
   (small) datagrams.
7. **A hole above the highest fragment index seen is not loss.** The first version
   NACKed every index a frame had not yet delivered, which turned every paced
   500 KB IDR into a retransmit storm — 2,942 NACKs on a lossless link. Only holes
   *below* the highest index received count, plus a tail timer for when the last
   fragment is missing. This is now spelled out in the spec.
8. **The pacer's rate follows the whole backlog, not the newest frame.** Setting it
   from one frame's size let a small predicted frame queued behind a 500 KB IDR
   drop the rate back and strand the IDR past its deadline.
9. **Frames are delivered in `frame_id` order, with a short hold queue.** A small
   predicted frame often completes before the large IDR in front of it. Discarding
   it as undecodable, as a purely reference-based gate does, threw away a frame
   that was a millisecond from being decodable.
10. **The decodability gate is per reference kind, not global.** A global gate
    closed by a gap also blocked the `ltrAny` refresh frame that exists to fix it,
    making LTR recovery impossible — 717 frames gated and 2 delivered under 2%
    loss.
11. **A `realtime` stream is not decodability-gated.** The plan's stream classes
    say gating belongs to `media`; gating audio withheld perfectly playable Opus
    packets and triggered a keyframe storm.
12. **The INIT's padding goes inside the sealed body.** Padding after the sealed
    body leaves the receiver unable to tell where the ciphertext ends without a
    length field, and an unauthenticated tail an attacker can strip. Inside, the
    length is implied by the datagram and the padding is authenticated.
13. **The INIT replay guard is the client ephemeral, not the timestamp.** A
    monotonic timestamp resets when a client reboots, which would lock that client
    out. The ephemeral is fresh per handshake, so a repeat is a replay.
14. **A reassembly slot is kept after its frame is consumed.** Without that, a NACK
    answered just after a frame was delivered reassembled and delivered it twice.
15. **A reliable channel's `msg_seq` starts at 0 and restarts at 0 on resume.**
    Bootstrapping the receiver's expectation from whichever segment arrived first
    skipped a lost leading message permanently.
16. **A FEEDBACK ack credits the reliable segment its datagram carried.** Recording
    every control datagram as just `.control` meant reliable segments were never
    acked and were resent until their message was dropped.

## Next steps

The plan's phases this PoC covers end to end but not exhaustively:

- Widen the scenario suite to the plan's full 60-second runs by default (they are
  behind `LIGHTRAY_LONG_SCENARIOS=1` today).
- `LightrayDebugOverlay`, and wire `NWPathMonitor` into `LightrayClient`.
- Split the merged modules if the boundaries need enforcing.
- Recorded benchmark thresholds in CI, rather than baselines in a document.
