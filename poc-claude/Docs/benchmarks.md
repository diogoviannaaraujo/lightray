# Recorded baselines

Measured on an Apple M4 (10 cores), macOS 26.5, Swift 6.2, release builds.
Reproduce with:

```bash
cd Benchmarks && BENCHMARK_DISABLE_JEMALLOC=true swift package benchmark
```

All figures are p50 total CPU time. The micro-benchmarks use a scaling factor of
1000 per sample, because package-benchmark's per-sample overhead is about 1.7 µs
and would otherwise swamp a 12 ns parse.

## Wire and crypto, per packet

| Benchmark | p50 | Instructions | Note |
|---|---|---|---|
| Header encode | 1 ns | ~1 | 16 bytes |
| Header decode | 1 ns | 17 | |
| Fragment parse | **12 ns** | 271 | Phase 0 spike measured 15.8 ns |
| Fragment parse and place at `index × stride` | **33 ns** | 515 | the realistic receive-path unit |
| Plaintext protector, 1168 B | 22 ns | 567 | a 1168-byte memcpy: the floor |
| Replay window accept | 14 ns | ~2300 | 2048-bit window |
| FEEDBACK encode, 200 packets | 533 ns | | 2.7 ns per reported packet |
| FEEDBACK decode, 200 packets | 130 ns | | 0.65 ns per reported packet |
| AES-128-GCM seal, 1168 B | 1354 ns | 27 K | Phase 0 spike: 1.29 µs |
| AES-128-GCM open, 1168 B | 1432 ns | 28 K | Phase 0 spike: 1.27 µs |

**The receive path excluding crypto is 33 ns against a 250 ns budget**, so the
target holds with a factor of seven to spare. Crypto costs about 50× the parse,
which is why it is excluded from the budget and why the plaintext protector exists
for isolating protocol cost.

## Full sans-IO pipeline, per frame

One frame from `submit` on the host through fragmentation, pacing, protection,
reassembly, decodability gating and delivery on the client, with feedback coming
back — **both sides** of the protocol, no sockets.

| Benchmark | p50 | Share of a 60 fps frame budget |
|---|---|---|
| 1080p60 at 20 Mbps, AES-GCM | **212 µs** | 1.3% |
| 1080p60 at 20 Mbps, plaintext | 84 µs | 0.5% |
| 4K60 at 80 Mbps, AES-GCM | **526 µs** | 3.2% |
| 4K60 at 80 Mbps, plaintext | 137 µs | 0.8% |
| 500 KB IDR fragment and reassemble, plaintext | 398 µs | 436 fragments |

60 fps is the ceiling; nothing above it is a target. At 4K60 the protocol costs
3.2% of the frame budget, against roughly 18 ms — over 100% of one 60 fps interval
— for the hardware encoder alone. **Resolution matters far more than the protocol.**

Crypto is 60–75% of the pipeline cost, as expected from the per-packet numbers.

## Transport, mac → mac on 127.0.0.1

One 1200-byte datagram out and back on loopback, sealed and opened, on one thread:

| Benchmark | p50 wall clock |
|---|---|
| Loopback 1200 B with AES-GCM | **4.67 µs** |
| Loopback 1200 B plaintext | 5.04 µs |
| `sendto` + `recvfrom` alone | 4.71 µs |

**The syscalls are the floor, not the protocol.** AES-GCM disappears inside the
socket cost, which matches the Phase 0 finding that `sendto` alone costs about
4 µs and there is no public batching API (`sendmsg_x` is private). At 1200 bytes
per 4.67 µs round trip that is **2.0 Gbps on a single thread** — but that is a
syscall ceiling for a bare seal-and-send loop, not what the whole runtime does.
For that, see below.

## The whole runtime, end to end

`lightray-poc selftest` reports the client loop thread's own CPU, broken down by
phase. Two rates, 6 s each, over 127.0.0.1:

| | 20 Mbps | 80 Mbps |
|---|---|---|
| datagrams received | 12,751 | 49,447 |
| loop turns | 9,607 | 25,381 |
| loop CPU | 487 ms, **8.1% of a core** | 784 ms, **13.1% of a core** |
| per loop turn | 50.6 µs | 30.9 µs |
| — kqueue wait | 5.0 µs | 3.9 µs |
| — drain socket and handle | 31.9 µs | 20.9 µs |
| — timers and commands | 4.9 µs | 2.4 µs |
| per datagram | 38 µs | 16 µs |

Two things to read from this.

**Per-datagram cost falls as the rate rises**, because a good share of a turn is
fixed: one kqueue wait and one failing `recvfrom` to find the socket empty,
whatever arrived. At 80 Mbps the loop gets 1.9 datagrams per wake instead of 1.3.

**The full stack costs more per datagram than the micro-benchmarks suggest** — 16 µs
at 80 Mbps against roughly 6 µs for a whole send-and-receive fragment pair in the
sans-IO pipeline benchmark. Two syscalls account for about 10 µs of that; the rest
is the difference between a tight benchmark loop with a hot working set and a real
loop where every datagram arrives cache-cold and reassembly writes 1149 bytes at a
time into a 500 KB buffer.

So the honest single-thread ceiling for the **whole runtime** is a few hundred
Mbps, not the 2 Gbps the syscall benchmark allows. That is consistent with the
Phase 0 note that 1 Gbps is "headroom over the working range, not a working
point": the spike reached it with a bare seal-and-send loop that had no protocol
in it. Against the 20–80 Mbps this protocol actually targets, 8–13% of one core
leaves plenty of room.

The per-phase counters are permanent, not scaffolding: `CLOCK_THREAD_CPUTIME_ID`
costs 72 ns a read on an M4, so ten reads a turn is under 1 µs of the tens of
microseconds a turn takes.

## Allocations

`swift test -c release --filter AllocationTests` counts allocations through
libmalloc's `malloc_logger` hook and asserts **zero** for:

- encoding and decoding a header plus a media fragment, 20,000 packets
- path and stream statistics updates, 20,000 updates
- replay-window and serial-number arithmetic, 20,000 updates
- placing fragments into a reassembly slot, 300 placements

package-benchmark's own malloc metric is **not** used: Phase 0 established it
reads 0 without jemalloc even for code that allocates on every iteration.

A debug build reports about one allocation per iteration for the same code —
closure boxing and retain/release traffic that optimisation removes — so the
assertion is release-only and merely prints in debug.

The one documented exception is crypto: CryptoKit has no in-place AEAD API and
CommonCrypto exposes no public GCM, so seal and open always allocate (Phase 0
measured 4 and 7 allocations per packet).
