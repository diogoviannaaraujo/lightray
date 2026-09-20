# Architecture

## The shape

```
                    app (encoder, decoder, capture, UI)
                                  |
   LightrayRuntime   ------------------------------  the only module that
   UDPSocket, EventLoop, LightrayHost/LightrayClient  touches Darwin
                                  |
   LightrayEngine    ------------------------------  sans-IO: no sockets,
   Connection, HostEndpoint, ClientEndpoint,          no threads, no clock
   Fragmenter, Reassembler, Pacer, RetransmitStore,
   DecodabilityTracker, ReliableChannel, BitrateController
                                  |
   LightrayCrypto    ------------------------------  CryptoKit
   handshake, key schedule, packet protection, replay window
                                  |
   LightrayCore      ------------------------------  no Foundation
   Instant, byte cursors, BufferPool, Bitset, stats, wire codecs
```

`LightrayTestSupport` sits beside the engine with a manual clock, a discrete-event
network and a synthetic frame source. `lightray-poc` is the demo executable.

## Sans-IO

Every state machine is synchronous and non-`Sendable`, with no socket, thread or
clock inside it. Inputs are `handle(datagram:from:at:)`, `handleTimeout(at:)` and
app commands; outputs are `pollTransmit(into:at:)`, `pollEvent()` and
`nextTimeout(at:)`. Nothing reads a clock on its own — the caller passes `at:`.

Three things follow. Scenario tests run in virtual time and give the same answer
every run, including a 30-minute grace window in a few milliseconds of real time.
Benchmarks price the whole pipeline without a socket. And the engine needs no
locks, because one connection belongs to one thread.

The runtime is thin by design: read the socket, call the engine, write what it
hands back, arm one timer. The public `LightrayHost` and `LightrayClient` are safe
to hand around because every method either posts to a mutex-protected command
queue or reads a mutex-protected snapshot.

## Where the bytes live

Nothing is copied that does not have to be.

- **Sending.** The app hands over an `EncodedFrame` whose storage is *retained,
  not copied*, until the frame leaves the retransmit window. The frame header is
  built once into a pooled buffer, and fragment `i` is then bytes
  `[i × stride, (i+1) × stride)` of `header ‖ payload` — so the fragmenter never
  looks at what it is carrying, and a retransmission costs no extra memory
  because it is re-derived from the frame the app already gave.
- **Receiving.** A fragment is placed straight into one contiguous pooled buffer
  at `index × stride`. When the frame is complete that buffer becomes the
  `ReceivedFrame` the app holds, and returns itself to the pool when the last
  reference goes. A decoded frame can be released on the decoder's thread, so
  buffers come back through a mutex-protected reclaimer that the loop thread
  drains on its next turn.
- **Reading.** The hot path parses through a `~Escapable` `RawSpan` cursor, so a
  parser can never outlive the datagram it reads. Frame-header parsing works over
  byte ranges instead, because the receiver owns that buffer and holds it across
  an asynchronous decode, which a non-escapable span cannot survive.

## What the measurements decided

Phase 0 measured suppositions rather than assuming them, and several results
changed the design:

- **Only `NOTE_CRITICAL` timers are precise.** A plain `kevent` timeout wakes about
  25% late and `EVFILT_TIMER` with `NOTE_NSECONDS` about 50% late, with
  `NOTE_LEEWAY` making no difference. The loop uses `NOTE_CRITICAL`.
- **`EVFILT_USER` triggers coalesce.** A wake is not one-to-one with a trigger, so
  the loop drains its whole command queue every time rather than counting.
- **`IP_DONTFRAG` and `IP_TOS` fail with EINVAL on a dual-stack socket.**
  `IPV6_DONTFRAG` works and covers v4-mapped peers; Swift does not import it, so
  its value (62) is written out.
- **Socket buffers cap at 8 MB** regardless of what is asked for.
- **`sendto` costs about 4 µs**, more than AES-GCM, and there is no public
  batching API. The syscall is the floor.
- **`DataRateLimits` is silently ignored** in low-latency mode, so there is no
  encoder-side per-frame cap — which is what makes the pacer necessary rather than
  optional.
- **A decoder handed a frame with missing references does not reliably fail.**
  H.264 returns success and outputs corruption. That is why `DecodabilityTracker`
  exists.
- **VideoToolbox attaches an LTR token to every frame and will not let the app
  pick the reference.** The app passes every acked token plus `ForceLTRRefresh`
  and the encoder chooses, so the refresh frame is marked `ltrAny` and the
  receiver accepts it unconditionally — sound because it only acks frames it
  decoded.
- **HEVC parameter sets are not in-band** and no decoder can be built without
  them, so every IDR carries its own `CODEC_CONFIG`.

## Deferred behind seams

Each of these is plumbed through both paths with a v0 implementation, so adding
the real thing does not move any other code:

| Seam | v0 |
|---|---|
| `FECScheme` | `NONE`, with the TLV present on every fragment |
| congestion control | manual bitrate plus a loss backstop |
| `PacingPolicy` | a frame-spreading token bucket |
| `NackPolicy` | the default timers |
| intra-refresh | a reserved capability, never accepted |
| rekeying | a reserved `key_phase` bit |
