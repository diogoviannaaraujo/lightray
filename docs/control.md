# Control messages

> **Version 0 text, to be rewritten for version 1** ([gaps.md](gaps.md)). Version 1 changes:
>
> - the client proposes settings when it connects and can change them at any time; the host
>   applies what it can and reports what it applied;
> - resolution, chroma and HDR changes force an IDR, and no other change does;
> - the bitrate is chosen by rate control ([rate-control.md](rate-control.md)), within the
>   maximum the client sets;
> - presets, the individual controls, and the host's mode hint are in [modes.md](modes.md);
> - settings scoped to one video stream, among them the display it shows, and a `DISPLAYS`
>   message listing the host's displays ([displays.md](displays.md)).

Configuration changes travel as reliable messages on **stream 0**, which is always
present, always bidirectional and always of class `RELIABLE`. They are therefore
ordered, acknowledged and retransmitted like any other reliable message; see
[input.md](input.md).

There are three messages and they share one shape:

```
msg_type:u8
req_id:u32
scope_stream:u8
TLVs[...]                 type:u8, length:u16, value
```

| `msg_type` | Name | Sent by |
|---|---|---|
| 1 | `RECONFIGURE` | either side, to request a change |
| 2 | `RECONFIGURE_RESULT` | the side that applied it |
| 3 | `STATE` | either side, to declare its current configuration |

`scope_stream` is **0** for a change that applies to the connection, or a stream
identifier for one that applies to a single stream. A receiver MUST discard a message
naming a stream that is not in the negotiated table.

> **Why one shape for all three.** The three messages differ only in what they mean, not
> in what they carry: a request, a result and a snapshot are all "a set of configuration
> values, in a context". Giving each its own layout would mean three parsers, three
> places to get a field width wrong, and no way to add a field to all three at once.

A receiver MUST skip a TLV whose type it does not recognise, using its declared length,
and MUST reject a message whose TLV lengths do not exactly consume the message.

Configuration TLV numbers, widths and valid ranges are in
[registries.md](registries.md).

## RECONFIGURE (1)

Requests a change. It carries only the fields being changed; omitting a field means
"leave it alone".

```
01000000090001000400b71b00030004
0a0005a0040002007805000101
```

| Bytes | Value | Field |
|---|---|---|
| `01` | 1 | `msg_type`, `RECONFIGURE` |
| `00000009` | 9 | `req_id` |
| `00` | 0 | `scope_stream`, the connection |
| `01 0004 00b71b00` | 12 000 000 | `BITRATE` |
| `03 0004 0a00 05a0` | 2560×1440 | `RESOLUTION` |
| `04 0002 0078` | 120 | `FRAMERATE` |
| `05 0001 01` | 1 | `HDR` |

`req_id` is chosen by the requester and MUST be unique among its outstanding requests.

Bitrate changes ride this same path. There is no separate bitrate message.

> **Why one path for every parameter.** Resolution, frame rate, bitrate and datagram
> size all have the same lifecycle: requested by one side, applied or refused by the
> other, and reflected in a generation number that frames then carry. Giving bitrate its
> own message because it changes more often would duplicate all of that for no gain.

## RECONFIGURE_RESULT (2)

The answer. It carries the values **actually applied** — not the values requested —
along with the new generation and a mask of what was refused.

A receiver of a `RECONFIGURE` MUST reply with exactly one `RECONFIGURE_RESULT` carrying
the same `req_id`.

### Partial application

The applier MUST apply every field it can and refuse only those it cannot. For each
refused field it MUST set bit `type − 1` of `REJECTED_MASK`, where `type` is the
configuration TLV type.

A field is refused when its value is outside the valid range in
[registries.md](registries.md), or when the applier cannot honour it.

```
02000000090001000400b71b00030004
0a0005a0040002003c05000101070004
0000000509000400000008
```

| Bytes | Value | Field |
|---|---|---|
| `02` | 2 | `msg_type`, `RECONFIGURE_RESULT` |
| `00000009` | 9 | `req_id`, matching the request |
| `00` | 0 | `scope_stream` |
| `01 0004 00b71b00` | 12 000 000 | `BITRATE`, applied |
| `03 0004 0a00 05a0` | 2560×1440 | `RESOLUTION`, applied |
| `04 0002 003c` | **60** | `FRAMERATE`, *not* the 120 requested |
| `05 0001 01` | 1 | `HDR`, applied |
| `07 0004 00000005` | 5 | `CONFIG_GENERATION` |
| `09 0004 00000008` | bit 3 | `REJECTED_MASK`: TLV 4, `FRAMERATE` |

The requester learns both facts from one message: the frame rate stayed at 60, and that
was a refusal rather than an oversight.

> **Why partial rather than all-or-nothing.** A request that changes four things and is
> refused entirely because one of them was out of range leaves the requester to work out
> which, by bisecting. Applying what is valid and naming what was not is one round trip
> instead of several, and matches what the requester wanted: a better configuration, not
> an atomic transaction.

## STATE (3)

A complete snapshot of the current configuration. Unlike `RECONFIGURE`, it carries
**every** field, so a receiver can adopt it wholesale without merging.

`req_id` is 0 when the message is unsolicited.

```
03000000000001000401312d00020004
001e848003000407800438040002003c
05000100060002010007000400000005
08000101
```

| Bytes | Value | Field |
|---|---|---|
| `03` | 3 | `msg_type`, `STATE` |
| `00000000` | 0 | `req_id`, unsolicited |
| `00` | 0 | `scope_stream` |
| `01 0004 01312d00` | 20 000 000 | `BITRATE` |
| `02 0004 001e8480` | 2 000 000 | `BITRATE_FLOOR` |
| `03 0004 0780 0438` | 1920×1080 | `RESOLUTION` |
| `04 0002 003c` | 60 | `FRAMERATE` |
| `05 0001 00` | 0 | `HDR` |
| `06 0002 0100` | 256 | `MAX_DATAGRAM_SIZE` |
| `07 0004 00000005` | 5 | `CONFIG_GENERATION` |
| `08 0001 01` | `RESUME` | `STATE_FLAGS` |

A sender MUST send `STATE` when:

- a session resumes, with the `RESUME` flag set — see [reconnect.md](reconnect.md); or
- the loss backstop engages or clears, with `BACKSTOP` reflecting the current state —
  see [feedback.md](feedback.md).

Both flags MAY be set at once.

## The configuration generation

`CONFIG_GENERATION` is a `u32` that the applier increments **whenever an applied change
alters the configuration**. It MUST NOT be incremented when a `RECONFIGURE` changes
nothing, and MUST NOT be incremented by the requester.

Every frame header carries the generation it was produced under; see
[video.md](video.md). That is what lets a receiver know which frames belong to the old
configuration and which to the new, without guessing from timing.

A receiver MUST treat a frame whose `config_generation` is newer than the configuration
it holds as belonging to a configuration it has not yet learned. It MUST NOT discard the
frame on that basis alone — the `STATE` or `RECONFIGURE_RESULT` may simply be in flight
behind it.

> **Why frames carry a generation at all.** A resolution change makes every buffer the
> receiver has allocated the wrong size, and the change takes effect at some frame the
> receiver cannot otherwise identify. Carrying the generation makes the boundary
> explicit and unambiguous, and makes a stale frame that arrives after the change
> recognisable rather than corrupting.

Generation comparisons MUST use `u32` serial-number arithmetic.
A generation change alone MUST NOT invalidate decoder references or break the `PREVIOUS` chain.
In particular, bitrate, frame-rate and datagram-size changes preserve prediction across the generation boundary.
A self-contained newer-generation IDR MAY be decoded before its reliable configuration message arrives; a stale frame MUST NOT roll back the current configuration.

## Changes that force a keyframe

A change to `RESOLUTION` or `HDR` MUST produce an `IDR` as the first frame of the new
generation, carrying its own `CODEC_CONFIG`.

> **Why.** Both change the decoder's parameter sets, and a decoder built for the old ones
> cannot decode the new ones. Since every `IDR` carries `CODEC_CONFIG`, the receiver gets
> the new parameter sets attached to the first frame that needs them, and needs no
> separate signalling.

A change to `BITRATE` or `FRAMERATE` MUST NOT force a keyframe.

A change to `MAX_DATAGRAM_SIZE` takes effect on the next frame submitted and MUST NOT
force a keyframe; see [packets.md](packets.md) for how in-flight frames are handled.

## Defaults

A session begins at generation 0 with the configuration agreed in the handshake. If a
field is absent from the handshake's `CONFIGURATION` TLV, these values apply:

| Field | Default |
|---|---|
| `BITRATE` | 20 000 000 |
| `BITRATE_FLOOR` | 2 000 000 |
| `RESOLUTION` | 1920×1080 |
| `FRAMERATE` | 60 |
| `HDR` | 0 |
| `MAX_DATAGRAM_SIZE` | 1200 |
