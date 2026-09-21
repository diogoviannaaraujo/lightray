# Lightray protocol, version 0

Lightray is a UDP protocol for low-latency interactive streaming: one machine (the
**host**) sends encoded video and audio to another (the **client**), and the client
sends back input, and optionally microphone and camera media. It is built for the case
where a person is controlling what they are watching, so a late frame is worse than a
missing one.

This directory is the protocol definition. It is complete enough to build a conforming
host or client from, in any language, without reference to any existing implementation.

## What the protocol does

- **Establishes a session** in one round trip, using a pairing secret the application
  supplies out of band, plus fresh ephemeral keys. Every packet after that is encrypted
  and authenticated.
- **Carries media as frames**, fragmented across datagrams and reassembled by the
  receiver, with enough information for a receiver to know when a frame is complete,
  when it is beyond saving, and when it is unsafe to decode.
- **Recovers from loss** by retransmission first, then by asking the sender for a frame
  that repairs the reference chain, and only then by a keyframe.
- **Survives the client going away** — a changed network, a closed lid, a user walking
  off — and resumes the same session without re-pairing.
- **Reports what is happening** on the path continuously, so an application can show
  link quality and a future congestion controller has what it needs.

## What the protocol does not do

- **It does not encode or decode anything.** Media payloads are opaque. Version 0 pins
  the codecs (see below) so that no codec identifier is ever carried, but the protocol
  never inspects a payload.
- **It does not capture or inject input.** Input streams carry bytes the application
  defines; see [input.md](input.md).
- **It does not traverse NAT**, discover peers, or handle pairing. The application
  supplies an address and a pre-shared key.
- **It does not control its own bitrate.** Version 0 changes bitrate only when the
  application asks, with one safety backstop; see [control.md](control.md).

## Codecs are pinned to the version

Version 0 means **H.265 (HEVC)** video and **Opus** audio at 48 kHz in 20 ms packets.
Nothing on the wire carries a codec identifier. A peer that disagrees about codecs
disagrees about the version, and fails the version check instead of negotiating.

> **Why.** Codec negotiation is a large, rarely exercised surface that exists to serve a
> flexibility this protocol does not need: both ends ship together. Pinning them to the
> version turns a negotiation failure into a version failure, which is simpler to
> specify, simpler to test, and impossible to get subtly wrong.

The HEVC profile, HDR and long-term reference-lifetime contracts remain incomplete; see [gaps.md](gaps.md) before assuming independent video interoperability.

## How to read this directory

| Document | Read it when |
|---|---|
| [handshake.md](handshake.md) | Establishing a session, deriving keys, negotiating streams |
| [packets.md](packets.md) | Building or parsing any packet after the handshake |
| [video.md](video.md) | Sending or receiving video, or implementing loss recovery |
| [audio.md](audio.md) | Sending or receiving audio |
| [input.md](input.md) | Carrying input, or media in the client-to-host direction |
| [feedback.md](feedback.md) | Reporting what arrived, requesting repair, measuring the path |
| [control.md](control.md) | Changing configuration mid-session |
| [reconnect.md](reconnect.md) | Parking, resuming, rebinding, expiry |
| [registries.md](registries.md) | Looking up any number that appears on the wire |
| [conformance.md](conformance.md) | Checking an implementation, or handling bad input |
| [gaps.md](gaps.md) | Finding out what version 0 leaves unresolved |

## Conformance language

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHALL**, **SHALL NOT**, **SHOULD**,
**SHOULD NOT**, **RECOMMENDED**, **MAY** and **OPTIONAL** are to be interpreted as
described in RFC 2119.

Text in a blockquote beginning **Why** is rationale. It explains a decision and is not
normative; an implementation is never obliged by it.

## Notation

- All integers are **unsigned and big-endian** unless the field is explicitly named as
  signed. `u8`, `u16`, `u32`, `u64` and `i16` denote widths in bits.
- All lengths count **bytes**, and a length field never includes its own width or the
  width of the type tag that precedes it.
- `a ‖ b` is concatenation. `x[m..n)` is bytes `m` up to but not including `n`.
- Field diagrams list fields top to bottom in wire order.
- Hex examples are shown as raw bytes, 16 per line, and are decoded underneath. They are
  generated, not written by hand; every one can be reproduced from the inputs the
  document states.
- **Reserved** means: a sender MUST write zero, and a receiver MUST ignore the value.
  This is what lets a later version use the space without a version bump.

## A session at a glance

```
client                                                        host
  |                                                             |
  |--- INIT (padded to max_datagram_size) --------------------->|
  |<-- RESPONSE (session_id, accepted parameters) --------------|
  |                                                             |
  |=== protected datagrams, both directions ===================>|
  |     media fragments, reliable messages, feedback, NACKs     |
  |<============================================================|
  |                                                             |
  |--- PARK --------------------------------------------------->|  host releases
  |                          (silence)                          |  media buffers
  |--- RESUME (from a new source port) ------------------------>|  host rebinds
  |<-- STATE, then a keyframe ----------------------------------|  and resumes
  |                                                             |
```

A session begins with one round trip and ends when either side sends `CLOSE`, when the
grace window expires, or when the host forgets it. Everything in between is protected
datagrams.

## Datagram size and the payload budget

`max_datagram_size` is the size of the **UDP payload**, excluding IP and UDP headers. It
is proposed by the client, accepted or lowered by the host, and MAY be changed
mid-session. It MUST be between **256 and 9000** bytes inclusive. The default is
**1200**.

A media fragment travels alone in its datagram, so its budget is fixed:

| Component | Bytes |
|---|---|
| Protected header | 16 |
| Chunk header (`type`, `length`) | 3 |
| Fragment header | 13 |
| FEC extension TLV | 3 |
| Authentication tag | 16 |
| **Total overhead** | **51** |

At the default 1200 bytes that leaves **1149 payload bytes per fragment**, 95.75% of the
datagram. This quantity is called the **stride**, and it is carried on every fragment;
see [video.md](video.md).

> **Why 1200 by default.** It fits inside the smallest path MTU that can be relied on
> across tunnels and consumer links without fragmentation. The protocol proves the path
> can carry it by padding the INIT to exactly `max_datagram_size` and setting
> don't-fragment, so a path that cannot carry the chosen size fails during the handshake
> rather than silently later.

## Versioning

The version is a `u8` carried in the clear in the first two bytes of every handshake
packet. Version 0 is defined here.

A receiver that sees a version it does not implement MUST silently discard the packet
and SHOULD count the event. It MUST NOT reply, because a reply would be an
amplification opportunity and there is nothing to negotiate.

Versions 1–239 are reserved for future revisions of this protocol. Versions 240–255 are
reserved for private use and MUST NOT be assigned by a future revision.
