# Parking, rebinding, resuming and expiry

A client goes away constantly: the network changes, the lid closes, the user walks off.
The protocol treats an absent client as an ordinary state rather than a failure, so that
coming back costs one keyframe instead of a new pairing.

```
        ┌──────────┐   PARK, or 2 s of silence    ┌──────────┐
        │  ACTIVE  │ ───────────────────────────► │  PARKED  │
        └──────────┘                              └──────────┘
             ▲                                     │        │
             │  any authenticated packet           │        │  pipeline_idle_after
             └─────────────────────────────────────┘        ▼
                                                    ┌──────────────┐
                                                    │ PARKED, IDLE │
                                                    └──────────────┘
                                                            │  grace_window
                                                            ▼
                                                      ┌──────────┐
                                                      │ EXPIRED  │
                                                      └──────────┘
```

## Parking

A host MUST park a session when it receives a `PARK` chunk, and SHOULD park one that has
sent it nothing for `park_after_silence` (default 2 seconds).

A client keeps an active session warm by sending `FEEDBACK` while media is flowing, and a
`PING` every 250 ms when it is not. A host that receives neither for two seconds has a
client that is gone, whether or not it said so.

On parking, a host **MUST release** every buffer holding media:

- the retransmission store,
- media pacer queues,
- media reassembly state,
- the set of acknowledged long-term references.

It **MUST retain**:

- the traffic keys,
- the packet-number counters and the replay window,
- the negotiated stream table,
- the current configuration and its generation,
- the peer address,
- accumulated statistics,
- reliable sequence counters, unacknowledged outgoing messages, partial incoming messages, completed messages waiting for ordered delivery, and pending acknowledgements in both directions.

> **Why releasing media buffers matters.** Media buffers can occupy megabytes and become unusable across the forced keyframe on resume.
> Retained protocol metadata is small, but pending reliable messages consume additional bounded memory and MUST NOT be discarded merely to park.

On parking, a host MUST also perform the input reset ([input.md](input.md#the-input-reset)),
releasing every key, button and contact it holds for the client, so that nothing stays
pressed on the host while the client is away. Input the client has not had acknowledged
does not survive the park: the client clears it before resuming; see
[input.md](input.md#resetting-input-across-a-resume).

A parked session MUST NOT be sent anything, MUST NOT arm a per-session timer, and MUST
NOT consume processing. A host SHOULD expire parked sessions by sweeping the set
periodically rather than by timing each one.

A host MUST bound the number of parked sessions it holds — 128 is RECOMMENDED — and MUST
discard the oldest first when the bound is reached.

### `PARK` (`0x32`)

An empty body.

```
320000
```

`PARK` is advisory and MUST NOT be relied on: a client that loses its network cannot send
it. Its only purpose is to let a host park immediately instead of waiting out
`park_after_silence`.

A client MUST ignore a `PARK` it receives. Only a host parks.

## The idle threshold

After `pipeline_idle_after` (default 60 seconds, carried in handshake TLV 7) a host
SHOULD tell its application that the session is idle, so the application can tear down
its encoder and capture.

The session itself is untouched. A client returning later still resumes; it needs a fresh
encoder only because a resume forces a keyframe regardless.

> **Why this threshold is separate from expiry.** A paused encoder and an open capture
> device are the expensive things a park holds — far more than the session state. They
> can be released long before the session needs to be forgotten. Splitting the two
> thresholds lets a host free the expensive resource in a minute while keeping the cheap
> one for half an hour.

## Rebinding

A packet from an address other than the session's current peer rebinds that session only
if it authenticates, passes the replay window, and carries a packet number strictly
greater than any previously authenticated for that session. The full rule and its
reasoning are in [packets.md](packets.md).

**If the session was not parked, rebinding is silent.** No keyframe, no `STATE`, no
interruption.

> **Why a mid-stream address change needs no recovery.** A NAT rebinding or a move
> between access points changes the address the packets come from and nothing else. The
> keys are the same, the packet numbers continue, no media was lost. Forcing a keyframe
> would turn an invisible event into a visible one.

## Resuming

A client resumes by clearing its input streams ([input.md](input.md#what-the-client-does)),
creating a **new socket**, which gives it a new source port, and sending `RESUME` until
`STATE` arrives.

### `RESUME` (`0x33`)

```
flags:u8              bit 0 = decoder_lost
point_count:u8
points[point_count]:
  stream:u8           a client-to-host RELIABLE input stream
  msg_seq:u32         that stream's resume point
```

```
33000c010205000000070700000012
```

| Bytes | Value | Field |
|---|---|---|
| `33` | `0x33` | type, `RESUME` |
| `000c` | 12 | length |
| `01` | bit 0 set | `flags`: `decoder_lost` |
| `02` | 2 | `point_count` |
| `05` | 5 | `stream` |
| `00000007` | 7 | `msg_seq`, stream 5's resume point |
| `07` | 7 | `stream` |
| `00000012` | 18 | `msg_seq`, stream 7's resume point |

A client MUST set `decoder_lost` when its decoder no longer exists — which is the case
whenever the application tore the pipeline down, and after any resume that followed an
idle notification.

A host MUST read the flag. It MUST NOT assume either value.

A client MUST name every `RELIABLE` client-to-host input stream, each once, with the
resume point it fixed when it cleared that stream, and MUST send the same points in every
repeat of this `RESUME`; see [input.md](input.md#resetting-input-across-a-resume). A
client with no such stream sends `point_count = 0`.

A host MUST discard a `RESUME` whose length is not `2 + 5 × point_count`, that names a
stream twice, or that names a stream which is not a `RELIABLE` input stream the client
may send on.

A client MUST repeat `RESUME` with exponential backoff until `STATE` arrives, and
SHOULD start at 100 ms and cap at 2 seconds.

### What the host does

On the first authenticated packet for a parked session, the host MUST:

1. Rebind to the source address of that packet, if it differs.
2. Discard any remaining media pacer, `NACK` and media reassembly state in both directions, preserving reliable state.
3. Rearm reliable retransmission and enqueue `STATE` on stream 0 with the `RESUME` flag set, using the next retained sequence number after previously queued messages.
4. Produce an `IDR`, with its own `CODEC_CONFIG`, on every outbound video stream.

Repeated `RESUME` packets during the same active recovery MUST NOT reset reliable state or restart the media pipeline; the queued `STATE` is retransmitted by the reliable stream.
Every `RESUME`, whether or not the session was parked, applies its resume points as [input.md](input.md#what-the-host-does) describes; a point only ever moves a stream forward, so a repeat changes nothing.
An asynchronous encoder completion belonging to a parked or replaced session MUST NOT repopulate its media queues.

**A resume always produces a keyframe**, whether or not `decoder_lost` was set.

> **Why always.** The host released its retransmission store when it parked, so nothing
> before the resume can be repaired. The client's reference chain is broken at the gap
> and there is no frame that can bridge it. A keyframe is not a heavier option than the
> alternatives here; it is the only option.

> **Why `STATE` is sent even though a keyframe is coming anyway.** The configuration may
> have changed while the client was away, and the client has no way to discover that from
> the media. `STATE` is a full snapshot, so a returning client adopts the current
> configuration in one message rather than inferring it.

## Expiry

After `grace_window` (default 30 minutes, carried in handshake TLV 7) a host MUST discard
the session and its keys.

The window is measured in **host-running time**: time during which the host was awake and
running. A host that sleeps does not age its parked sessions while asleep.

A client that returns after the grace window will receive `SESSION_UNKNOWN` in response
to its `RESUME`; see [handshake.md](handshake.md). It then performs a new handshake,
which costs one round trip and a keyframe, and requires no re-pairing.

### Client fallback when the host has lost its state

A restarted host may have a different reset key, so its `SESSION_UNKNOWN` cannot necessarily be verified with the old session's reset token.
The client MUST NOT accept an unverifiable reset as proof that the session ended.
An active or resuming client MUST bound how long it waits without an authenticated response before abandoning the old session and starting a new handshake; 2 seconds is RECOMMENDED.
Only authenticated, replay-accepted incoming packets refresh this liveness timer.
The timer is suspended during intentional parking and starts afresh when the client first sends `RESUME`.
This fallback does not require re-pairing and does not prove the outcome of outstanding commands.

## System sleep is not parking

A host or client that is about to sleep MUST close its sessions. It SHOULD send `CLOSE`
if it still can, and MUST discard its traffic keys.

On waking, a client performs a **new handshake**. It MUST NOT attempt to resume across a
sleep.

> **Why sleep ends the session rather than parking it.** Two reasons, and either alone
> would be enough. A session that survives sleep has its traffic keys written into the
> hibernation image, where they sit unprotected for as long as the machine is off. And
> the monotonic clock's behaviour across sleep is platform-dependent, so every timer and
> every delay measurement in a resumed session would be resting on an assumption the
> protocol cannot make. Re-handshaking on wake costs one round trip and a keyframe — the
> same as a resume — and needs no re-pairing, because the pairing key is unaffected.

## Adopting a session on re-handshake

A client whose session was lost MAY name it in a new `INIT` using handshake TLV 6,
`RESUME_SESSION_ID`.

A host MAY adopt that session if it still holds it, it is parked, and it belongs to the
same pairing. On adoption:

- the session identifier, stream table, configuration and statistics **survive**;
- the traffic keys and the packet-number space in both directions are **replaced** by the
  ones this handshake derives, and the replay window is reset.

A new handshake, including adoption, MUST start reliable streams at sequence zero and MUST NOT automatically replay old pending commands into the new sequence space.
Both endpoints MUST report unresolved old command delivery to their applications; cross-handshake exactly-once execution requires application-level reconciliation.
This differs from ordinary resume with retained keys, which preserves pending commands and their sequence numbers.
Input is the exception on both sides: a client discards its unacknowledged input instead of reporting it, and a host that adopts a session performs the input reset; see [input.md](input.md#the-input-reset).

A host that does not adopt MUST allocate a new session identifier. The client learns
which happened from the `session_id` in the `RESPONSE`.

> **Why the packet numbers must restart.** A nonce is unique only within one key. New
> keys mean a new nonce space, so continuing the old counter would be harmless but
> pointless, while continuing the old *replay window* against new keys would reject
> legitimate packets. Both restart together.

## Timings

All values are in [registries.md](registries.md). The two that are negotiated —
`pipeline_idle_after` and `grace_window` — are carried by the host in handshake TLV 7 and
are therefore known to both ends. The rest are local policy.

A client SHOULD NOT assume the defaults. It MUST use the values the `RESPONSE` gave it.
