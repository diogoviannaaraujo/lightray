# Local Mac baseline — 20/09/2026

Measured in release on this Mac, arm64, 15 reported processors, 24 GB memory, macOS 26.6.1, Swift 6.4 / Xcode toolchain.
The host and client run on separate dedicated event-loop threads on the same machine, communicating through IPv4 loopback with AES-GCM enabled.
No video/audio codecs run in these measurements; frames contain deterministic synthetic bytes.
The 1 Gbps case is a headroom test, not an intended streaming bitrate.

| Case | Delivered frames | Payload Mbps including drain | Protected UDP Gbps | Frame latency p50 / p99 |
| --- | --- | --- | --- | --- |
| 1080p60 / 20 Mbps | 300 / 300 | 20.06 | 0.02096 | 1.14 / 1.50 ms |
| 4K60 / 80 Mbps | 300 / 300 | 80.09 | 0.08367 | 3.82 / 4.75 ms |
| 1 Gbps headroom | 300 / 300 | 998.66 | 1.04451 | 17.57 / 37.12 ms |
| 20 Mbps with park/resume and new port | 300 / 300 | 20.06 | 0.02097 | 1.13 / 1.88 ms |

All four runs reported zero runtime errors and zero authentication failures.
The 20 and 80 Mbps runs needed no NACKs or retransmissions.
The headroom run generated 2 NACK ranges and 786 retransmitted fragments; throughput includes that protocol traffic, while payload throughput counts completed frames only.
The reconnect run recorded one park and one resume with a different source port.
Latency is application-submit to frame event, not capture-to-display or encode-to-decode latency.

| Microbenchmark | p50 | p90 |
| --- | --- | --- |
| Header + fragment decode | 15 ns | 16 ns |
| Receive parse + actual fragment placement + statistics | 55 ns | 57 ns |
| AES-GCM seal + open, 1200-byte datagram | 3.185 µs | 3.322 µs |
| Fragment + reassemble 1080p frame | 3.501 µs | 3.625 µs |
| Fragment + reassemble 4K frame | 13 µs | 14 µs |
| Fragment + reassemble 500 KB IDR | 39 µs | 41 µs |
| Complete encrypted sans-IO 1080p frame | 374 µs | 389 µs |
| Complete encrypted sans-IO 4K frame | 857 µs | 893 µs |

The receive benchmark places distinct nonduplicate fragments into an existing assembly.
Frame setup and handshake setup are outside the timed regions; allocation/deallocation at frame boundaries is included in the frame benchmarks.
The allocation assertion warms the exact call path, then measures a separate sequence of distinct fragments and requires zero allocations on the measured thread.
The positive control requires at least one detected allocation per iteration, and the malloc hook is restored after each probe.
The benchmark runner can print a failed benchmark while exiting successfully, so the checker also inspects its output.

Recorded local thresholds are receive-path p90 below 250 ns, zero steady-state Wire/Streams/Stats allocations, at least 1 Gbps of authenticated protected UDP, complete frame delivery in all four loopback runs, and verified socket replacement during resume.
Run `python3 scripts/check-benchmarks.py` to validate the saved reports.
Run `scripts/benchmark-local.sh` to rebuild and replace them with a fresh sequential measurement.
These are machine-specific checks; scheduler load and other applications can affect latency and headroom results.
