# Input, data and reverse-direction media

Three things travel from client to host: input events, optionally microphone and camera
media, and whatever else the application wants to send. They use two chunk types and the
same machinery as everything else.

## RELIABLE (`0x02`)

An ordered, acknowledged byte-message stream. Used for input, and for the control
messages on stream 0.

```
stream:u8
msg_seq:u32
seg_index:u16
seg_count:u16
payload[...]              the remainder of the chunk
```

A message is split into `seg_count` segments, numbered from 0. A message of one segment
has `seg_count = 1` and `seg_index = 0`.

`msg_seq` numbers **messages**, not segments, and increments by one per message on that
stream. It starts at **0** on a new stream, and **restarts at 0** when a session resumes.

> **Why it restarts at 0 rather than continuing.** The receiver has to know where the
> sequence begins in order to detect that the very first message was lost. Bootstrapping
> the expectation from whichever segment happens to arrive first means a lost leading
> message is never noticed and never repaired — it is simply skipped. A known starting
> point makes the first message as recoverable as every other.

### Validation

A receiver MUST discard a segment unless `seg_count > 0` and `seg_index < seg_count`, and
MUST discard one whose `seg_count` disagrees with a segment of the same `msg_seq` it has
already accepted.

A receiver MUST bound the number of incomplete messages it holds, the size of a message,
and how far ahead of its expected `msg_seq` it will buffer. Exceeding any bound MUST be
reported as an error rather than met by growing.

### Delivery

A receiver MUST deliver messages to the application in `msg_seq` order, with no gaps. A
completed message whose predecessor has not arrived MUST be held until the predecessor
arrives.

### Acknowledgement and retransmission

A receiver acknowledges a fully received message by naming it in the acknowledgement
trailer of a `FEEDBACK` chunk; see [feedback.md](feedback.md). It MUST acknowledge a
message once it has all segments, whether or not the message has been delivered to the
application.

A sender MUST retain a message until it is acknowledged, and MUST retransmit its
unacknowledged segments after a retransmission timeout of `max(1.5 × srtt, 20 ms)`,
doubling on each attempt.

A sender MUST bound the number of unacknowledged messages it will hold and MUST report an
error rather than exceed it.

> **Why acknowledgement is explicit rather than inferred from the transport.** It would
> be possible to treat a reliable segment as acknowledged when the datagram that carried
> it is reported received, since `FEEDBACK` already reports datagram arrival. That
> requires the sender to keep a map from `transport_seq` to the segments that packet
> carried, and to maintain it correctly across retransmission — which is where it goes
> wrong: a segment credited to the wrong packet is retransmitted until its message is
> dropped. Naming the message directly costs five bytes and removes the map.

### Worked example

```
02000c000000000300010002010203
```

| Bytes | Value | Field |
|---|---|---|
| `02` | `0x02` | type, `RELIABLE` |
| `000c` | 12 | length |
| `00` | 0 | `stream` (the control stream) |
| `00000003` | 3 | `msg_seq` |
| `0001` | 1 | `seg_index` |
| `0002` | 2 | `seg_count` |
| `010203` | 3 bytes | payload |

## DATAGRAM (`0x03`)

An unreliable, unordered message. Sent once, never retransmitted, never acknowledged,
delivered to the application if it arrives and forgotten if it does not.

```
stream:u8
payload[...]              the remainder of the chunk
```

A `DATAGRAM` chunk MUST fit in one datagram; there is no fragmentation. A sender MUST NOT
submit a payload larger than `max_datagram_size − 36`.

```
0300060668656c6c6f
```

Type `0x03`, length 6, stream 6, payload `hello`.

## Input payloads are application-defined

**Version 0 does not define what bytes an input message contains.**

The protocol carries input as opaque payloads on a `RELIABLE` stream, in order and
without loss. What a key press, a pointer motion or a controller state looks like inside
that payload is the application's choice.

**The consequence is explicit: two independently written implementations will not
interoperate on input.** They will establish a session, exchange video and audio
correctly, and fail to agree about what an input message means. Anyone building a client
against a host they did not write MUST obtain the input encoding from the host's
author — it is not in this specification. See [gaps.md](gaps.md).

> **Why it is left open here.** Input encoding is bound to what the host does with it —
> which platform's event model, which controller abstraction, which coordinate space —
> and none of that is transport. Specifying a poor one now would be worse than
> specifying none, because implementations would carry it forever. It is named as a gap
> rather than quietly omitted so that nobody discovers it by building half a client.

An application SHOULD send input as one message per event or per coalesced batch, and
SHOULD keep messages small enough to fit in a single segment, so that a single loss costs
one round trip rather than a reassembly.

## Microphone and camera

Microphone and camera streams are **ordinary media streams in the reverse direction**.
They use `MEDIA_FRAGMENT`, the frame header, `NACK`, `FRAME_ACK` and `REFRESH_REQUEST`
exactly as host-to-client media does, and everything in [video.md](video.md) and
[audio.md](audio.md) applies unchanged.

The only differences are in the stream table:

| Stream | Kind | Direction | Class | Behaves as |
|---|---|---|---|---|
| Microphone | `MIC` | client → host | `REALTIME` | [audio.md](audio.md) |
| Camera | `CAMERA` | client → host | `MEDIA` | [video.md](video.md) |

The class, not the kind, determines the behaviour. A `MIC` stream declared as `MEDIA`
would be decodability-gated, which [audio.md](audio.md) explains is wrong for audio; a
host MUST honour the class in the table it accepted rather than inferring one from the
kind.

Microphone audio is Opus, mono, 48 kHz, 20 ms packets, decoded to stereo. Camera video
is HEVC. Both are pinned by the version, as in the forward direction.

## Direction enforcement

A receiver MUST discard a chunk that arrives on a stream whose direction does not permit
it — a `MEDIA_FRAGMENT` arriving at a client on a `client → host` stream, for example —
and SHOULD count the event.

A receiver MUST discard a chunk whose type does not match the stream's class: a
`MEDIA_FRAGMENT` on a `RELIABLE` or `UNRELIABLE` stream, a `RELIABLE` chunk on a `MEDIA`
or `REALTIME` stream, or any chunk naming a stream that is not in the negotiated table.

Stream 0 is the exception: it is always present, always bidirectional, and always
`RELIABLE`.
