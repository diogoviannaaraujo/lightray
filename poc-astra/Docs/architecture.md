# Architecture

The root package requires Swift 6.2 or newer and macOS 26 or newer, uses Swift 6 concurrency checking, and has no external library dependencies.
Only the nested Benchmarks package depends on the benchmark tooling.
The Phase 0 project remains independent under ../../Spikes.

## Ownership and scheduling

LightrayPrimitives, LightrayWire, and LightrayStats do not import Foundation.
The span cursor and bounded writer validate lengths before loads or writes and can be inlined across module boundaries.
The library enables the same experimental Lifetimes feature validated by the repository's spikes.

Connection, HostEndpoint, and ClientEndpoint are synchronous, non-Sendable engines.
They receive explicit instants and datagrams, expose queued transmits and events, and never access sockets, wall clocks, or threads.
Only handshake endpoints accept a separately supplied Unix timestamp for replay guarding.
A caller must drain events, drive timers, and keep each engine on one owner thread.
The simulation and Swift tests exercise these same engines.

The Darwin runtime creates a dual-stack nonblocking UDP socket, enables IPv6 don't-fragment (also effective for IPv4-mapped traffic), requests 8 MiB socket buffers, and records the kernel's effective sizes.
It uses SO_NET_SERVICE_TYPE_VI without promising that the network applies DSCP.
Each host or client runtime has one dedicated thread with kqueue readability, EVFILT_USER command wakeups, and a 1 ms NOTE_CRITICAL timer.
Commands are drained as a queue because user-event triggers can coalesce.
EAGAIN and ENOBUFS retain the unsent protected datagram for retry without resealing under a reused number.
NWPathMonitor ignores its initial notification and requests socket replacement on subsequent satisfied-path notifications.

Application buffers implement ByteStorage and remain retained through the retransmission window.
StoredFrame keeps the small serialized frame header separately and copies each fragment range directly from the retained storage into an outbound datagram.
The full encoded application frame is not copied at submission.
ReassembledFrame owns contiguous allocated storage and can safely remain alive through asynchronous decoder completion; its bytes remain valid while the frame object is retained.
Call reportDecoded only after the decoder confirms success, never just because a frame was delivered.
The standalone BufferPool provides fixed slabs; the current reassembler allocates its bounded contiguous backing storage per frame rather than returning completed frames to a shared pool.

The receive codec, existing-frame fragment placement, and PathStats update are measured separately from frame allocation and CryptoKit.
CryptoKit cannot perform in-place AES-GCM and its allocation cost is intentionally included in encrypted pipeline benchmarks.
The Connection convenience API also allocates datagram arrays and control messages; zero-allocation claims apply to the measured Wire/Streams/Stats steady-state primitive path, not the entire encrypted runtime.

## Recovery and bounds

Fragment stride is carried on every packet, so last-fragment-first delivery and retransmissions following an MTU change remain unambiguous.
Per-frame metadata must remain consistent and allocation limits are checked before reserving memory.
Completed frame IDs are retained in a bounded duplicate cache.
The decodability tracker gates generation changes and missing references before exposing a frame to a decoder.
Completed frames can wait in a bounded dependency-order queue while an earlier frame is recovered.

NACKs distinguish an observed hole from a tail that the pacer has not transmitted yet.
The retransmit store, reliable channels, reassembly, pending NACKs, pacer, replay window, event queue, and parked session table all have explicit caps.
Queue overflow is reported as an error event; callers should drain events and honor encoder pause/resume notifications.
The pacer prioritizes control, retransmissions, audio, and then video, with a default 256 KB burst cap and 2 Gbps link ceiling.
A smaller burst cap can be selected when constructing the standalone Pacer.

Parking drops the complete MediaState rather than retaining large queues for the grace period.
Stats and timeline persist, while traffic keys persist only until close or expiry.
Resume sends a new full state snapshot over reliable stream zero and requires an IDR for outgoing video.
The application connects the systemSleep hook to its macOS lifecycle notifications and calls connect on wake.
The runtime does not install application-global AppKit observers.

## Application seams

DecoderHost, AudioSink, and DisplayClock describe application integrations; codecs and input capture are outside this package.
Connection emits frame events with FrameInfo, and the runtime forwards these events on its event-loop thread.
Do not block this callback; retain the frame and hand it to your decoder's queue.
Return decode confirmation through the runtime command queue.
Statistics are readable through a Mutex-backed snapshot and a bounded AsyncStream with the newest snapshot published at most every 100 ms.
LightrayDebugOverlay is an independent SwiftUI product that renders those snapshots.

## Testing and measurement

Swift Testing covers wire bounds and fuzzing, cryptographic known answers and tampering, handshake retries and replay, reassembly, reliable ordering, recovery, bitrate backstop, parking, expiry, NAT rebinding, and real IPv4/IPv6 loopback.
The deterministic simulation uses a seeded PRNG and models Bernoulli loss, Gilbert–Elliott burst states, latency, jitter, reordering, blackouts, and serialized bottleneck queues.
Two 60-second scenarios exercise 3600 frames each on clean and 2% loss links.

Use scripts/ci.sh for debug/release validation and a short real-loopback run.
Use scripts/benchmark-local.sh for independent host/client UDP loops on the same Mac at 20, 80, and 1000 Mbps, plus a port-replacement run and the microbenchmarks.
Each loopback report includes delivered frames, payload throughput including drain time, protected UDP throughput, latency percentiles, authentication failures, NACKs, retransmissions, and runtime errors.
Numbers are synthetic transport measurements and exclude HEVC/Opus encoding and decoding.
Use the recorded machine-specific results in Docs/benchmarks as a baseline, not as a performance promise on other Macs.
