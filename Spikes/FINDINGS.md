# Definition.md supposition check (Phase 0 spikes)

Checked 2026-09-19 on an Apple M4 (10 cores) running macOS 26.5, with Xcode 26.0 / Swift 6.2 and the iOS 26.0 Simulator (iPhone 17).
Raw numbers from the macOS release build are in [`results-macos.txt`](results-macos.txt). The same probes also run as Swift Testing tests on the iOS Simulator. Those results are **functional only**, because `xcodebuild test` builds Debug and the micro-benchmark numbers it produces don't mean anything.

Legend: ✅ confirmed · ⚠️ holds, with a correction · ❌ false as written · ⏳ can't be tested on this machine

## Toolchain and package

| # | Supposition | Verdict | Evidence |
|---|---|---|---|
| 1 | Swift 6.2, Xcode 26.0, iOS 26 sims; `iPhone 17` destination | ✅ | Present. |
| 2 | `Span`/`RawSpan`/`InlineArray`/`Mutex`/`Atomic` usable at min OS 26 | ✅ | These compile and run on macOS and the iOS sim, as do `MutableRawSpan` and `OutputRawSpan`. (`Array(capacity:initializingWith:)` isn't in 6.2.) |
| 3 | **Spike 1:** `~Escapable` RawSpan cursor | ✅ | Needs `.enableExperimentalFeature("Lifetimes")`. The spelling is `@_lifetime`, and the `LifetimeDependence` flag is rejected. Mutating `Void` methods on `~Escapable` types need `@_lifetime(self: copy self)`, and `inout` `~Escapable` parameters need `@_lifetime(w: copy w)`. `Optional<~Escapable>` works (`nextChunk() -> Chunk?`). A span borrowed from a temporary doesn't compile (`slabs[i].bytes`); it does once the owner is bound to a local. A pool slab exposes a borrowed `RawSpan` via `RawSpan(_unsafeBytes:)` + `_overrideLifetime(_:borrowing:)`, which are underscored, unsafe stdlib API. |
| 4 | Apps can consume a package that uses `Lifetimes` | ✅ | A git (URL) dependency builds. The consumer target uses the `~Escapable` API **without** enabling the feature. |
| 5 | Hot-path helpers `@inlinable` across modules, zero allocations | ✅ | Parse: 15.8 ns with the span cursor vs 6.8 ns with raw pointers. Parse plus placing the payload at index×stride: 48 ns vs 31 ns (target < 250 ns). 0 allocations. package-benchmark shows 303 instructions and about 12 ns. 2 M fuzzed or truncated datagrams caused no trap. |
| 6 | `xcodebuild test -scheme Lightray-Package -destination 'platform=iOS Simulator,name=iPhone 17'` | ⚠️ | The scheme is named `<Package>-Package`, and Swift Testing runs on the sim. **The `-Package` scheme also builds every executable target for the iOS Simulator.** |
| 7 | `Benchmarks/` with package-benchmark, path-dependent on `../` | ✅ | package-benchmark 1.36.2 (plus swift-atomics) resolves, builds and runs on Swift 6.2. |
| 8 | "Allocation stats need jemalloc; without it set `BENCHMARK_DISABLE_JEMALLOC=true`" | ❌ | Without jemalloc the malloc metric still prints, and it reads **0** for a control benchmark that allocates once per iteration. `malloc_logger` saw 1000 allocations per 1000 iterations. libmalloc's `malloc_logger` hook counts allocations without jemalloc (these spikes use it as `AllocCounter`). |

## Crypto

| # | Supposition | Verdict | Evidence |
|---|---|---|---|
| 9 | **Spike 2:** CryptoKit AES-GCM cost and allocations per 1200-byte packet | ⚠️ | Seal: 1.29 µs, **4 allocations**. Open: 1.27 µs, **7 allocations**. Building the nonce takes 64 ns. The crypto-only ceiling is about 7.4 Gbps per core. CryptoKit has no in-place API, and CommonCrypto exposes no public GCM (macOS or iOS), so AES-GCM through system APIs always allocates. |
| 10 | Nonce = IV ⊕ 64-bit pn; 16-byte header as AAD; detached tag | ✅ | A tampered header, tampered body or wrong pn is rejected. The sealed length is plaintext + 16. |
| 11 | NNpsk0-shaped schedule from CryptoKit X25519 + HKDF + SHA-256 | ✅ | About 96 µs of math per handshake (both sides' ephemerals, DH, transcript hash, 4 outputs). |
| 12 | Stateless-reset token = HMAC(host secret, session_id) | ✅ | 1.3 µs and 12 allocations. |

## Clocks and event loop

| # | Supposition | Verdict | Evidence |
|---|---|---|---|
| 13 | `Instant` = continuous monotonic UInt64 ns | ✅ / ⏳ | `mach_continuous_time()` costs 3.7 ns (ticks; the timebase is 125/3 on M4). `clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)` costs 6.9 ns, and `ContinuousClock.now` about 20 ns. They share the same timeline. Counting through sleep is documented but wasn't observed, because this Mac hasn't slept since boot (`kern.sleeptime` = 0). |
| 14 | **Spike 3:** kqueue EventLoop with "precise timeouts" | ❌ | A `kevent` timeout wakes about 25% late (1 ms → +260 µs, 2 ms → +510 µs, 16.7 ms → +2 ms). `EVFILT_TIMER` with `NOTE_NSECONDS` is about 50% late (16.7 ms → +8.3 ms). `NOTE_LEEWAY` set to 0, 1 µs or 50 µs changes nothing. **Only `NOTE_CRITICAL` is precise:** median 5–30 µs and p99 ≤ about 170 µs from 100 µs to 16.7 ms. QoS user-interactive vs default makes no difference to timer precision. |
| 15 | `EVFILT_USER` for cross-thread commands | ⚠️ | Wake latency: median 6 µs, p99 about 20 µs. Triggers **coalesce** (`EV_CLEAR`): 7 of 200 merged on the sim at default QoS, so one wake can stand for several triggers. The first version of this probe counted wakes and hung. |
| 16 | Loopback latency | info | Loopback send → `EVFILT_READ` → `recv` takes a median of about 57 µs (p99 about 180 µs) on macOS. |

## Sockets

| # | Supposition | Verdict | Evidence |
|---|---|---|---|
| 17 | Dual-stack BSD socket | ✅ | With `[::]` and `V6ONLY=0`, v4 peers arrive as `::ffff:a.b.c.d`, and sending to v4-mapped addresses works. |
| 18 | Recreating the socket gives a new source port | ✅ | Each bind to port 0 got a different random port. |
| 19 | Big `SO_RCVBUF`/`SO_SNDBUF` | ⚠️ | Defaults: 0.75 MB receive, about 9 KB send. `setsockopt` accepts up to about 32 MB but **silently caps the effective value at 8 MB** (`kern.ipc.maxsockbuf`); `getsockopt` returns the capped value. ⏳ iOS device limits are unknown. |
| 20 | `IP_DONTFRAG`, so the padded INIT proves the path MTU | ❌ | On a dual-stack socket, `IP_DONTFRAG` **and `IP_TOS` fail with EINVAL**. `IPV6_DONTFRAG` works and also covers v4-mapped peers: a 1472-byte payload is sent, and 1473 fails with EMSGSIZE on the 1500-byte-MTU first hop (without DF, 1473 is fragmented and sent). Swift doesn't import `IPV6_DONTFRAG`, because it sits behind `__APPLE_USE_RFC_3542`; its value is 62. |
| 21 | `SO_NET_SERVICE_TYPE` for WMM | ⚠️ / ⏳ | All service types are accepted and read back, but **no DSCP is written** (TOS/TCLASS stays 0 for VI/VO/RV/AV/SIG). macOS marks DSCP only when `net.qos.policy.*` is on (all 0 here; that's the "QoS-capable"/Fastlane Wi-Fi case). The effect on the WMM access category happens inside the Wi-Fi driver, and checking it needs an over-the-air capture. On a dual-stack socket, `IPV6_TCLASS` sets the full byte for IPv6. For v4-mapped peers the kernel **keeps the 2 ECN bits and strips the 6 DSCP bits** (0xB9 → 0x01, 0xB8 → 0x00). `IPV6_RECVTCLASS` returns the full IPv4 TOS byte, including CE. **So ECN/L4S works on one dual-stack socket; IPv4 DSCP can only be set from an `AF_INET` socket.** |
| 22 | Loopback UDP with crypto ≥ 1 Gbps on a single loop thread | ✅ (thin margin) | Paced at 1 Gbps with AES-GCM: **1.00 Gbps delivered, 0 loss**. The sender spends 6.8 µs of CPU per packet, 71% of the 9.6 µs budget; the receiver spends 4.8 µs. Unpaced, the ceiling is 1.43 Gbps with crypto and 2.35 Gbps in plaintext. `sendto` alone costs about 4 µs per packet, more than the crypto. There's no public batching API (`sendmsg_x`/`recvmsg_x` are private). |
| 23 | `NWPathMonitor` triggers proactive socket replacement | ✅ / ⏳ | The initial path arrives in 1–3 ms on macOS and the sim. Transitions (Wi-Fi ↔ cellular, VPN) need a device. |

## VideoToolbox (what the recovery design and the zero-copy seams depend on)

| # | Supposition | Verdict | Evidence |
|---|---|---|---|
| 24 | The encoder can do LTR | ✅ | H.264 and HEVC hardware encoders with low-latency rate control on M4: `EnableLTR` is supported, and every property set succeeded. |
| 25 | An LTR refresh recovers without an IDR | ✅ | Frames 30–35 were lost; at frame 36 the encoder got `AcknowledgedLTRTokens` + `ForceLTRRefresh`. The result is a **P-frame (not sync)**, 0 decode errors, and frames 36–59 **bit-identical** to the no-loss decode, for both codecs. On synthetic content the refresh frame is 1.4–2.2× a P-frame and 0.74–0.88× the IDR. |
| 26 | "Receiver acks LTR-marked frames"; `.refreshRequired(.referencing(newestAckedLTR))` | ⚠️ | VT attaches `RequireLTRAcknowledgementToken` to **every** frame (60/60), and the app **can't pick** the reference: it passes every acked token + `ForceLTRRefresh`, and the encoder chooses. VT doesn't report which acked LTR the refresh frame references. |
| 27 | `DecodabilityTracker` is needed | ✅ | With 2 frames lost and no refresh, the **H.264 decoder returns noErr and outputs 4/4 corrupted frames**. HEVC returns `kVTVideoDecoderBadDataErr` (-12909). |
| 28 | `EncodedFrame` storage is retained, not copied | ✅ | Every encoder output `CMBlockBuffer` was a single contiguous block. |
| 29 | `DecoderHost` gets a zero-copy pooled frame | ⚠️ | A `RawSpan` is non-escapable, so it can't be held across the asynchronous decode. Pool memory wrapped as a `CMBlockBuffer` with a `CMBlockBufferCustomBlockSource` decoded correctly, and the free callback returned 54/54 buffers to the pool. |

## Wire arithmetic (checked by calculation)

| # | Supposition | Verdict | Evidence |
|---|---|---|---|
| 30 | 49-byte overhead, 1151-byte payload at 1200 | ✅ | 16 header + 16 tag + 3 chunk + 11 fragment + 3 FEC TLV. |
| 31 | `SESSION_UNKNOWN` is always smaller than the packet that triggered it | ✅ | 21 bytes, while the smallest protected datagram is 32 bytes. |
| 32 | FEEDBACK encoding | ⚠️ | One 1200-byte datagram covers at most **543** received packets, so reporting every packet takes at least 58 feedback datagrams/s at 300 Mbps and 192/s at 1 Gbps. An `i16 × 4 µs` delta spans only ±131 ms; longer arrival gaps (idle, stalls) can't be encoded as a delta. `u32` µs timestamps wrap every 71.6 min. |
| 33 | RTT from the feedback hold time (no PING) | ✅ | Valid, because both terms come from the receiver's clock. |
| 34 | 2048-bit replay window | ✅ | Tolerates 19.7 ms of reordering at 1 Gbps and 393 ms at 50 Mbps. |
| 35 | `RetransmitStore` 500 ms / 16 MB | ⚠️ | The cap wins above about 270 Mbps (447 ms at 300 Mbps, 134 ms at 1 Gbps). That's still far more than the 25–50 ms frame deadlines. |
| 36 | Receiver places each fragment at `index × stride` | ⚠️ | No field carries the stride; it's only known from a non-last fragment, so a last fragment that arrives first can't be placed yet. At a 1200-byte `max_datagram_size` the stride is 1151. |
| 37 | The pacer spreads a 500 KB IDR over one frame interval | ✅ | That needs 240 Mbps momentarily at 60 fps (480 at 120), which is what `linkRateCeiling` bounds. 1 ms `NOTE_CRITICAL` ticks produce 25–50-packet bursts. A paced loop built this way hit exactly 1.00 Gbps. |

## iOS Simulator lifecycle run ([`LifecycleProbe/`](LifecycleProbe))

`LifecycleProbe` is a real iOS app. It runs the planned loop shape on one thread (a 100 ms `NOTE_CRITICAL` heartbeat, `EVFILT_READ` on a dual-stack socket, and `EVFILT_USER` commands from the lifecycle hooks) and reports to a UDP listener on the Mac. The app was backgrounded by opening Settings in front of it and brought back with `simctl launch`. The event timeline is in [`LifecycleProbe/results-simulator.txt`](LifecycleProbe/results-simulator.txt).

The simulator runs iOS's own app-lifecycle system (SpringBoard / RunningBoard) on the **Mac's kernel**. So the lifecycle *policy* is meaningful here, but anything the kernel does to a suspended app's sockets is not.

| # | Supposition | Verdict | Evidence |
|---|---|---|---|
| 38 | `didEnterBackground()` sends PARK | ✅ | PARK reached the host in both runs. The loop thread sent it about 11 ms after the notification. |
| 39 | Time left after backgrounding | ⚠️ | **Without a background task, the process was suspended about 0.3 s after `didEnterBackground`.** With `beginBackgroundTask`, the app ran for 26.3 s until the expiry handler fired, plus 5.1 s more, before suspension. `backgroundTimeRemaining` read `DBL_MAX` in both cases. |
| 40 | `willEnterForeground()` recreates the socket and sends RESUME | ⚠️ | A scene-based (SwiftUI) app also gets `willEnterForeground` about 0.25–0.29 s after a **cold launch**, and the probe replaced its socket and "resumed" a session that had never parked. |
| 41 | Timers and the loop thread across suspension | ✅ | The kqueue, the loop thread and its timers survive suspension and run within about 0.17 s of the foreground request. Missed periodic timer fires collapse into one wake, so the engine sees one `handleTimeout` with `now` jumped by the whole suspension (15–28 s here). |
| 42 | The socket dies during suspension, hence replacement | ⏳ | **The simulator doesn't reproduce this.** After 15–28 s suspended, the old socket still sent, `SO_ERROR` was 0, and 5 datagrams sent to it while it was suspended were still buffered and delivered on resume. Unconditional replacement worked immediately (new port, first heartbeat within 70 ms). What a device does to the old socket (the errors, and when) is still untested. |

## H.264 vs HEVC ([`results-codec.txt`](results-codec.txt), `spikes codec`)

Both codecs ran on the M4's hardware encoder and decoder in Lightray's configuration: low-latency rate control, `RealTime`, no frame reordering, LTR on. Frames were fed at real-time pace, and latency was measured from submit to output. The content is a 3840×2160 photo filmed by a virtual camera. A plain pan is pure integer translation, which both encoders find trivially easy: they hit their quality ceiling and leave most of the bitrate unused. So the rate–distortion numbers come from a **zoom-and-drift** camera (sub-pixel, non-translational motion, resampled every frame), where both encoders use their full budget.

| # | Question | Result |
|---|---|---|
| 43 | Encode latency | HEVC is **+0.2–0.8 ms** at 1080p (median about 5.7 ms for H.264 vs about 6.1 ms) and **+1.2–1.5 ms** at 4K (about 17.3 vs 18.6 ms). The cost is set by resolution, not by the codec, frame rate (30/60/120) or LTR. **4K encode costs about 18 ms on a base M4 for either codec**, more than one 60 fps frame interval. |
| 44 | Decode latency | Median the same (1.6–2.0 ms at 1080p, 2.5–3 ms at 4K). HEVC has **tighter tails at 4K**: p99 5–6.5 ms vs 5.5–10 ms for H.264, and a worst frame of at most about 9 ms vs up to 27 ms. |
| 45 | Compression at equal bitrate | HEVC is +2.5 / +2.2 / +1.6 / +1.1 dB Y-PSNR at 2 / 4 / 8 / 16 Mbps (1080p60), which is **about 25–45% fewer bits for the same quality**, more at low rates. IDRs are 12–20% smaller at equal bitrate. |
| 46 | Frame-size spikes | At equal *bitrate*, HEVC's low-latency rate control is spikier: at 4 Mbps the p99 P-frame is 3.0× the per-frame budget (H.264 2.0×) and the max is 5.7× (H.264 2.9×). At equal *quality* (HEVC 4 Mbps ≈ H.264 8 Mbps) HEVC's median frame is half the size, its p99 is about the same (25 vs 27 KB), and its single worst frame is larger (47 vs 36 KB). |
| 47 | Frame-size controls | In low-latency mode, **`DataRateLimits` is accepted but silently ignored** (the output is byte-identical to the uncapped run). `ConstantBitRate` and `PrioritizeEncodingSpeedOverQuality` are rejected (-12900). There is no encoder-side per-frame cap in low-latency mode. |
| 48 | Encoder frame drops | Under a tight budget both encoders **skip frames** (1080p60: 8–10 of 180 at 2 Mbps, 2 at 4 Mbps; 4K: 4 of 180 at 10 Mbps). A skipped frame produces no output at all, and the displayed cadence stutters. |
| 49 | Capabilities | H.264 produced **no frames at 4K120** in low-latency mode; HEVC did 4K120 at the same ~19 ms latency. With missing references, HEVC reports `kVTVideoDecoderBadDataErr` while H.264 silently outputs garbage (#27). HEVC Main10 is the only hardware 10-bit/HDR path on Apple. Every device that runs iOS 26 or macOS 26 has hardware HEVC encode and decode. |

**Verdict: HEVC doesn't make latency meaningfully worse.** It costs under 1 ms of encode at 1080p and about 1.3 ms at 4K. In exchange, at the same quality, it puts about 40% fewer bytes on the wire (fewer packets to pace, retransmit and lose), recovery IDRs are smaller, and 4K decode tails are tighter. The one real cost is frame-size variance at a given bitrate; at equal quality the difference mostly disappears (#46). Resolution matters far more than codec: 4K encode alone is about 18 ms.

### API parity ([`results-codecapi.txt`](results-codecapi.txt), `spikes codecapi`)

The same scripted 1080p stream ran through each codec's low-latency hardware encoder (LTR on, acks one frame late): a forced keyframe at 60, bitrate 8 → 3 Mbps at 90 and → 12 Mbps at 150, a second forced keyframe at 180, and 60 → 30 fps at 200. The earlier probes had already shown HEVC parity for LTR tokens on every frame, `ForceLTRRefresh` recovery, contiguous output, zero-copy pooled decode and decode errors on missing references (#24–29).

| # | Needed for | H.264 | HEVC | Evidence |
|---|---|---|---|---|
| 50 | Everything | 109 properties | 109 properties | **Identical supported-property sets** in low-latency mode. Unsupported by both: `OutputBitDepth`, `ConstantBitRate`, `MaxFrameDelayCount`, `MaxH264SliceBytes` (so no slice control even on H.264). `DataRateLimits` is listed but ignored (#47). |
| 51 | IDR on demand (resume, `.idr` refresh) | ✅ | ✅ | `ForceKeyFrame` gives a true IDR: NAL type 5 for H.264, 20 (IDR_N_LP) for HEVC, never CRA. LTR tokens continue across it. |
| 52 | Resume with `decoder_lost` | ✅ | ✅ | A fresh decoder built **only from the parameter-set bytes** and joining at a forced keyframe decoded with 0 errors, bit-identical to the continuous decode. |
| 53 | Parameter sets | 2 sets (SPS 21 B + PPS 4 B) | 3 sets (VPS 26 B + SPS 48 B + PPS 7 B) | **Not in-band**: keyframes contain only the IDR slice. They never changed across keyframes, bitrate or frame-rate changes, so they change only with a new session (resolution/profile). A decoder can't be created without them. |
| 54 | RECONFIGURE bitrate / frame rate | ✅ | ✅ | Applied live on the next frame: at 3 Mbps both achieved 2.8, and at 12 Mbps 11.5 (H.264) / 11.8 (HEVC). After switching to 30 fps they achieved 12.0 / 11.2. No extra keyframes were inserted. A resolution change means a new session, new parameter sets and an IDR, the same for both. |
| 55 | HDR TLV | ❌ | ✅ | HEVC Main10 + BT.2020 + PQ works in low-latency mode with LTR on: a 10-bit stream that decodes cleanly. H.264 accepts 10-bit input and the PQ tags but **outputs 8-bit**, which would band. |
| 56 | Intra-refresh (reserved) | ❌ | ❌ | VideoToolbox has no intra-refresh property or frame option for either codec. The reserved capability can't be implemented with Apple encoders. |
| 57 | Future loss resilience | ✅ | ✅ | Both support `BaseLayerFrameRateFraction` (temporal layering). |

**Verdict: everything the design needs exists for HEVC, with behaviour identical to H.264, plus HDR, which only HEVC has.** Two gaps are codec-independent: parameter sets aren't in-band, and intra-refresh isn't available.

## Still unverified (needs hardware or privileges)

- **iOS device:** HEVC low-latency + LTR encode on the iPhone's encoder (needed for the reverse camera stream); when sockets go defunct after suspension and which errors they return (the simulator keeps them alive); background time budgets on real hardware; `NWPathMonitor` transitions; socket buffer caps; `NOTE_CRITICAL` precision and energy cost; CryptoKit speed on A-series; VT LTR on the iPhone hardware encoder.
- **On the wire:** whether the DF bit is actually set (the local EMSGSIZE is strong evidence), and whether `SO_NET_SERVICE_TYPE` picks the WMM category. Both need a packet or Wi-Fi capture.
- **Continuous clock across sleep:** this Mac hasn't slept since boot.
- **An Xcode app project** consuming the package. SwiftPM URL-dependency resolution was checked; an `.xcodeproj` target wasn't.

## Re-running

```bash
cd Spikes && swift build -c release && .build/release/spikes all      # or: cursor crypto clocks timers sockets throughput video path
```

```bash
cd Spikes && xcodebuild test -scheme Spikes-Package -destination 'platform=iOS Simulator,name=iPhone 17'
```

```bash
cd Spikes/Benchmarks && BENCHMARK_DISABLE_JEMALLOC=true swift package --allow-writing-to-directory .benchmarkBaselines benchmark
```

Lifecycle probe: start a UDP listener on 127.0.0.1:47000, then build, install and launch the app. Background it by opening another app, and reopen it. Launch with `-bgtask` to take a background task on backgrounding.

```bash
cd Spikes/LifecycleProbe && ./build.sh && xcrun simctl install booted build/LifecycleProbe.app && xcrun simctl launch booted dev.lightray.lifecycleprobe
```

The `sockets` probe sends at most four datagrams to reserved documentation addresses (192.0.2.1, 2001:db8::1) to test don't-fragment. On the iOS Simulator that part is skipped.
