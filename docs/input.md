# Input, data and reverse-direction media

> **Version 0 text, to be rewritten for version 1** ([gaps.md](gaps.md)). Version 1 changes:
>
> - the keyboard as USB HID usages (page 0x07), plus UTF-8 text and lock-state sync;
> - the pointer as relative motion or as a position on one of the host's displays, naming the
>   display and normalised to it ([displays.md](displays.md#the-pointer-and-the-cursor)), and
>   the wheel in 1/120-notch units;
> - gamepads in the W3C "standard gamepad" layout, with arrival, removal and rumble;
> - a host-to-client cursor channel: visibility, the shape as RGBA plus a hotspot cached by id,
>   the position with the display it is on, and a request that the client capture the pointer;
> - camera, touch, pen and motion sensors get reserved numbers only;
> - stream classes and direction enforcement moved to [packets.md](packets.md#streams).

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

`msg_seq` numbers messages, not segments, independently per stream and direction.
It starts at **0** on a new reliable stream and increments modulo 2³²; zero is valid.
Ordinary park/resume MUST preserve the next outgoing number and the next expected incoming number.
A receiver MUST NOT bootstrap its expectation from the first packet after resume or accept a later number by skipping a missing command.
The one exception is a resume point, which moves an input stream's expectation forward; see [Resetting input across a resume](#resetting-input-across-a-resume).
Comparisons use serial-number arithmetic, and the receive window MUST remain smaller than 2³¹ messages.

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

### Parking and resuming

Both peers MUST retain outgoing unacknowledged messages, incoming partial messages, completed messages held for ordered delivery, pending acknowledgements, and sequence counters across ordinary park/resume.
The client-to-host direction of an input stream is the exception: it is cleared and resynchronised instead, as [Resetting input across a resume](#resetting-input-across-a-resume) describes.
A completed message held behind a gap MUST survive even if it has already been acknowledged: its sender may have released its copy.
Retransmission timers MUST pause while parked and MUST be rearmed on resume.
Retained commands remain pending and MUST be delivered once, in their original order; resume does not cancel them.
Duplicate fully received messages MUST be acknowledged again without being delivered again.
Retention remains subject to the same memory bounds as an active stream; exhaustion MUST report an error rather than silently discard commands.
A new handshake starts a new reliable sequence space, including when it adopts a session identifier; see [reconnect.md](reconnect.md).

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

The protocol carries input as opaque payloads: on `RELIABLE` streams, in order and
without loss while the session is active, and for high-rate updates on an `UNRELIABLE`
stream; see [Splitting input by device](#splitting-input-by-device). What a key press, a
pointer motion or a controller state looks like inside that payload is the
application's choice.

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

## Splitting input by device

An application SHOULD give each input device its own stream, so that a loss on one
device never delays another: a lost mouse message must not hold up a key press queued
behind it. Order matters only within a device — a click must land where the motion before
it left the pointer — and a stream preserves exactly that order.

| Stream | Carries | Class |
|---|---|---|
| Keyboard | key presses and releases, and text | `RELIABLE` |
| Mouse | motion, buttons and scroll | `RELIABLE` |
| Touch | contacts going down, up and cancelled | `RELIABLE` |
| Pen | contacts going down, up and cancelled, and button changes | `RELIABLE` |
| One per gamepad | the controller's full state, and a gyroscope stopping | `RELIABLE` |
| High-rate updates | touch and pen hover and move, and motion sensors | `UNRELIABLE` |

Every one is an `INPUT` stream in the client-to-host direction. Which stream carries which
device is part of the application-defined input encoding. The stream table cannot change
during a session, so an application MUST allocate its gamepad streams at the handshake —
one for each gamepad it supports, within the table's 32-entry limit.

Text travels on the keyboard stream so that typed text and the key that submits it stay
in order.

> **Why one stream per device.** A `RELIABLE` stream delivers in order, so one lost
> message holds back everything after it on that stream until it is retransmitted. With
> every device on one stream, a lost pointer update delays an unrelated key press by a
> round trip. Separate streams confine the delay to the device that lost the message.

### Discrete events are never merged

Key presses and releases, text, mouse buttons, scroll, touch and pen contacts going down,
up or cancelled, and pen button changes are sent on their device's `RELIABLE` stream, one
message per event. A client MUST NOT merge, reorder or drop them while the session is
active.

### Motion and state are merged before sending

A client keeps at most one motion message waiting on the mouse stream, and at most one
state message waiting on each gamepad stream. A message is waiting from when it is built
until it is handed to the transport. While one is waiting, newer input is merged into it
rather than queued behind it:

- relative mouse motion adds its deltas to the waiting message;
- absolute mouse position replaces the waiting position;
- a gamepad state replaces the waiting state, **unless its buttons differ**. A button
  change ends the merge and starts a new message, so that the host receives the exact
  stick and trigger positions at the moment of the press.

A client SHOULD hand the mouse stream at most one motion message per
`input_merge_interval` (1 ms by default), holding a newer one back so that it absorbs the
motion that follows. Once handed to the transport, a message is never changed.

> **Why merging lowers latency.** Pointing devices report up to a thousand times a
> second. Sent one message per report, motion fills the stream with updates that must
> each be delivered, in order, before the next — and after a loss, all of them are
> retransmitted before anything newer. Merging bounds what is waiting to one message, so
> the next thing sent is always the newest position.

### High-rate updates are unreliable

Touch and pen hover and move, and motion-sensor readings, are sent as `DATAGRAM` chunks
on the `UNRELIABLE` input stream, each carrying the latest value. A lost update is
replaced by the next. A client SHOULD send at most one per device per
`input_merge_interval`.

Two such updates go on the device's `RELIABLE` stream instead, because losing either would
leave the host in the wrong state with nothing coming to correct it:

- a pen move that changes the pen's buttons;
- a gyroscope reading of all zeros, which means the gyroscope has stopped.

An `UNRELIABLE` stream is unordered, and is not ordered against the reliable streams. Its
payload MUST therefore let the host discard an update older than one it has already
applied — a counter per device is enough, and a reliable reading that stops a gyroscope
carries it too. A host MUST ignore an update for a touch or pen contact that the reliable
stream has not put down.

> **Why these are unreliable and motion is not.** A hover position or a sensor reading is
> replaced by the next one within milliseconds, so retransmitting a lost one only delays
> the newer value behind it. A relative mouse delta is different: a lost one is movement
> that never happens, and nothing after it repairs it. The last update before a device
> goes still has the same problem, because nothing follows it. That is why mouse motion
> and gamepad state are reliable and kept cheap by merging, and why a stopping gyroscope
> is sent reliably.

## Resetting input across a resume

An input event means something only at the moment it was made. A click delivered after a
long park lands on whatever is on screen by then, and typed text goes to whatever window
has focus. Input is therefore the one thing a resume discards rather than delivers.

This section replaces the rules in [Parking and resuming](#parking-and-resuming) for the
client-to-host direction of input streams. Stream 0 and every other reliable stream keep
those rules.

### The input reset

The input reset returns everything the host holds on the client's behalf to rest. The
host releases every held key and mouse button, lifts every touch and pen contact, and
sets every gamepad and sensor to neutral. It SHOULD keep each gamepad's virtual device
present, so that software on the host does not see the controller unplugged. A host MUST
track what it holds in order to do this, and MUST ignore a release of anything it does
not hold.

A host MUST perform the input reset:

- when it parks a session;
- when a session ends, by `CLOSE` or by expiry;
- when it adopts a session on re-handshake;
- for one stream, when a resume point moves that stream forward, as described below.

The reset is local to the host. Nothing is sent.

A key the user is still holding when the session resumes stays released on the host
until it is pressed again. Gamepad messages are state rather than events, so a client
SHOULD send each gamepad's current state as the first message on its stream after a
resume.

### What the client does

Before it sends the first `RESUME`, a client MUST clear each of its `RELIABLE`
client-to-host input streams:

- it discards every message that has not been acknowledged, whether or not it was sent,
  including a motion or state message still waiting to be merged;
- it keeps the stream's next `msg_seq`. The first message sent after the clear uses that
  number, and the count continues from it.

That number is the stream's **resume point**. The client MUST name every `RELIABLE`
client-to-host input stream and its resume point in `RESUME` (see
[reconnect.md](reconnect.md#resume-0x33)), and MUST send the same points in every repeat
of that `RESUME`, even after it has sent newer messages. A client that parks again before
`STATE` arrives clears again and names new points.

A client also discards any update it has not yet sent on an `UNRELIABLE` input stream.
Those streams have no sequence to resume.

A client that performs a new handshake instead of resuming discards its unacknowledged
input the same way. The new handshake starts every stream at 0.

### What the host does

When a `RESUME` arrives — whether the session is parked or active — the host takes each
stream it names and, if the resume point is ahead of the `msg_seq` it next expects on
that stream:

1. performs the input reset for that stream;
2. discards every partial message, and every completed message it holds, below the
   resume point;
3. sets its next expected `msg_seq` to the resume point, and delivers any messages it
   holds from there onward.

"Ahead" uses the serial-number arithmetic above. A resume point at or behind the expected
number changes nothing, so a repeated or late `RESUME` is harmless. A stream the `RESUME`
does not name keeps its expectation.

Once a stream has moved forward, a message below its expected `msg_seq` is a duplicate:
the host acknowledges it and does not deliver it.

A host can park a session whose client never parked it — after two seconds of silence,
for example. That client clears nothing and sends no `RESUME`, so its input continues
under the ordinary rules. The input reset at park has still released whatever was held.

### Messages already in flight

A message sent before the park can arrive after it. What happens depends only on whether
it arrives before or after the host applies the resume point:

- **Before**, it is delivered as usual. A message in flight arrives within moments of
  being sent, however long the park lasts, so acting on it is no different from acting
  on it slightly late. If its stream then moves forward, the reset releases anything it
  pressed. If the stream does not move forward, every message the client sent before the
  resume point has arrived, including any release that followed it.
- **After**, it is below the expected number and is discarded as a duplicate.

In neither case does the host wait for a message the client discarded, and in neither
case does a key stay down because its release was cleared.

> **Why the numbers continue instead of restarting.** If the client reused the numbers of
> the messages it cleared, a delayed original and its replacement would share a
> `msg_seq`. Whichever arrived first would be delivered and the other dropped as a
> duplicate, so a stale event could be delivered in place of a fresh one, or segments of
> the two combined into one message. Continuing the count gives every message a number no
> other message has had, and the resume point tells the host where the gap ends.

> **Why the reset happens where a stream moves forward.** Parking already released
> everything, but a message in flight can press a key after that, and the release that
> followed it may be one the client cleared. The host can know that a release will never
> come only at the moment it skips the gap, so that is where it releases. The reset is
> per stream so that a key pressed on one stream after the resume is not released because
> a different stream skipped.

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
