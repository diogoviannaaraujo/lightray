# poc-ng: executable video protocol review

This is an independent implementation of the video path described in `../docs/`, built to expose ambiguities by sending real HEVC through encrypted UDP and decoding it under impaired network conditions.
It does not import either older PoC, and it is not a production transport SDK or a claim of full protocol conformance.

## Run

Python 3.12+ is required; the tested environment and exact library versions are recorded in the results.
PyAV wheels supply FFmpeg, including libx265 and the HEVC decoder; no separate FFmpeg executable, privileged network configuration, or additional service is required.

```sh
cd poc-ng
python3 -m venv .venv
.venv/bin/python -m pip install -e '.[test]'
.venv/bin/python -m pytest -q
.venv/bin/python -m ng.demo --seconds 6 --output artifacts/matrix
```

The default run generates a three-second HEVC MP4 test pattern with motion, then loops its decoded pictures through a live HEVC encoder.
A live encoder is necessary to answer recovery requests with genuine new IDRs; replaying an immutable elementary stream would not test that behavior.
Use a local video as the source with `--input /absolute/path/sample.mp4`; raw H.265 files are also accepted by PyAV.

```sh
.venv/bin/python -m ng.demo --input /absolute/path/sample.h265 --scenarios clean,random_loss,blackout,park_resume --seconds 10
.venv/bin/python -m ng.demo --width 1920 --height 1080 --fps 60 --bitrate 8000000 --scenarios clean,random_loss --seconds 6 --output artifacts/1080p
.venv/bin/python -m ng.demo --scenarios lost_recovery --seconds 4 --strict-recovery --output artifacts/strict-recovery
```

The last command is an intentional negative experiment: with the pre-revision recovery retry rule, it exits nonzero because the lost recovery frame is never replaced.
The regular mode uses the explicitly documented recovery-attempt policy in [FINDINGS.md](FINDINGS.md).

## What actually happens

```text
HEVC sample -> PyAV demux/decode -> live libx265 encoder -> Lightray host UDP socket -> bounded impairment relay -> Lightray client UDP socket -> live HEVC decoder -> pixel comparison
```

Host, client and relay have separate real IPv4 UDP sockets on localhost, with don't-fragment enabled.
Both directions traverse the relay, including handshake, reliable control, feedback and repair requests.
Endpoint decisions never consult the relay's impairment state or the reference decoder.
A clean decoder processes every outgoing access unit, and the received decoder's visible Y/U/V samples must match its SHA-256 result exactly.
The hash is local test instrumentation and is not added to the wire.
Every saved received `.h265` stream is also reopened through an independent FFmpeg demux/decode pass, and its decoded frame count must match the live receiver.

The encoder uses HEVC 8-bit 4:2:0, no B frames, a single short-term reference, and closed GOPs.
Forced recovery output is checked for actual IDR NAL types 19/20, rather than trusting a generic keyframe flag that could also mean CRA.
LTR is not advertised, so fallback to IDR follows the negotiated capability set.

## Measurements and artifacts

Each run writes `summary.json`, `summary.md`, per-frame timing/hash JSON, protocol event JSON and received `.h265` streams.
The compact checked-in results are in [results/](results/); generated video and detailed traces stay under ignored `artifacts/`.

- Latency: encoder submission to received decoded output, with p50/p95/p99/max.
- Stage timing: encode, submit-to-decoder transport time, reassembly, and actual decoder call time.
- Reliability: frames submitted/decoded, pixel mismatches, NACKs, retransmissions, expired frames and recovery requests.
- Continuity: maximum inter-decoded-frame gap, action-to-next-decoded-frame time and missed capture scheduling opportunities.
- Network: offered/delivered bytes and datagrams, injected loss, queue drops, corruption, duplication, reordering and MTU drops.

The latency clock is the same machine's monotonic clock for both endpoints.
This is not glass-to-glass latency: sample demux/decode and image conversion happen before the simulated capture timestamp, and display/rendering is absent.
The clean reference decode and its hash run before submission and therefore add harness overhead to the end-to-end measurement.
Per-frame percentiles include only decoded frames; the delivery ratio and maximum decode gap must be read alongside them.
During a park or handshake no frames are submitted, so the delivery ratio alone does not describe that interruption.

The relay uses a fixed PRNG seed, independent directional serialization queues, propagation delay, jitter, random loss, Gilbert-style burst loss, duplication, reordering, corruption, a bounded queue and an MTU ceiling.
Wall-clock scheduling is not deterministic, so the seed makes the impairment choices repeatable for a given packet sequence, not the measured latencies or packet sequence itself.
These are controlled localhost experiments, not measurements of real Wi-Fi, cellular radios, kernel netem, or remote clock synchronization.

## Coverage

The full matrix covers clean/LAN/WAN/high RTT, random and burst loss, reverse-path loss, reordering and duplication, authentication failures caused by corruption, a bottleneck queue, a dropped handshake response, blackouts, a lost recovery frame, decoder reset, active source-port rebinding, park/resume, a lost resume STATE, session expiry, loss of host cryptographic state, MTU reduction, resolution change, and frame-rate change.
Host restart is modeled by discarding its session, keys, reset-token key and INIT cache; the test runner process itself stays alive.
A scenario passes only if decoded pixels match, the stream produces output near the end, its delivery ratio exceeds its declared floor, and its specific lifecycle assertions hold.
Destructive scenarios deliberately have lower delivery floors; PASS means the asserted transport/recovery behavior worked, not that the link met a latency or visual-quality service-level target.
Terminal no-output time is reported separately so a stream that never recovers cannot hide behind percentiles calculated from its earlier surviving frames.

Unit tests additionally exercise documented crypto/feedback vectors, malformed inputs, replay/packet-number wrap, frame-ID wrap, stale control after resume, whole-frame loss, paced-tail NACK suppression, out-of-order completion, original-stride retransmission, reliable segmentation/ordering, partial reconfiguration, and memory bounds before frame allocation.
Expected failures are reserved for four contradictions in the published worked examples, and remain visible in pytest output.

## Deliberate limits

- One forward video stream and reliable control stream 0; audio, input, reverse camera, multiclient scaling, NAT traversal and public network deployment are outside this experiment.
- No hardware LTR or Main10/HDR execution; those still require the VideoToolbox/device tests identified in the existing spikes.
- The FFmpeg libx265 adapter does not expose verified live bitrate reconfiguration, so bitrate changes are explicitly refused, and a sustained-loss backstop trigger is reported as unsupported rather than falsely claiming the encoder was clamped.
- Frame-rate changes update submission cadence and protocol generation without an IDR; this does not verify a live update of the encoder's internal rate-control frame-rate model.
- Local liveness timeout, recovery-attempt expiry, skip-zero frame-ID wrap, and paced-tail timing are experiment policies now reflected in the revised documentation.
- The host is a single-peer fixture; session adoption, real process suspension/sleep, pipeline teardown after a long idle period, and adversarial production resource hardening are not implemented.
- Bounded frame buffers exist, but per-frame measurement records grow with experiment duration; this is intentional diagnostic retention, not a long-running streaming service.

## Small dependency surface

[PyAV](https://pyav.org/docs/stable/) supplies codec, demuxing, muxing and pixel conversion.
[cryptography](https://cryptography.io/en/latest/hazmat/primitives/) supplies X25519, HKDF and AES-GCM.
Python's standard library supplies UDP, asynchronous scheduling, the impairment model, hashing, CLI parsing and reports; pytest supplies tests.
The FFmpeg [libx265 wrapper](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/libx265.c) is the relevant boundary for live encoder reconfiguration support.
No codec, cipher, UI framework, dependency injection framework, or third copy of the old Swift engine was added.

## Documentation revision

The protocol docs now preserve pending reliable commands and sequence numbers across ordinary resume.
The demo runtime still implements the earlier reset behavior; updating that implementation is separate work.
Published wire examples are checked directly by `tests/test_documentation.py`, including real HEVC decoding and protected-datagram authentication.
Archived results describe the original experiment and have not been relabeled as validation of the revised resume behavior.
