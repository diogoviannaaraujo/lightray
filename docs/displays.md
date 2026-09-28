# Displays

A host can have several displays, and a client can show several of them at once. Each display
the client shows travels on a video stream of its own, and each stream is independent of the
others: its own frames, its own settings, its own losses and its own keyframes. Everything else
in the session exists once: the transport, the rate, the audio, the input, the microphone and the
cursor.

This document is version 1. It defines the model and the rules. The byte layouts of the
messages it describes belong to the documents that carry them, and arrive as those are rewritten;
[Where the bytes go](#where-the-bytes-go) lists them.

> **Why a stream per display.** The alternatives are one stream showing the whole desktop, or one
> stream switched between displays. The first sends pixels the client may not show, at a size no
> encoder handles well once displays are side by side at 4K. The second makes a client with two
> screens choose. A stream per display lets each one be sized, paced and repaired for the screen
> it lands on, and the stream table already carries several streams of one kind.

## The host's displays

A host describes each display it can stream:

| Field | Meaning |
|---|---|
| `display_id` | `u32`, chosen by the host, never 0 |
| `flags` | Whether this is the host's primary display, and whether it can show HDR |
| `width`, `height` | The display's current mode in pixels |
| `refresh` | Its refresh rate in millihertz |
| `x`, `y`, `layout_width`, `layout_height` | Where it sits in the host's desktop, in the host's own desktop coordinates; `x` and `y` are signed |
| `name` | UTF-8, at most 64 bytes, for a client to show in a picker; not necessarily unique |

The layout rectangle gives the arrangement of the displays, so that a client can place its
windows the way the host's screens are arranged, and, against the pixel size, each display's
scale.

A host MUST NOT reuse a `display_id` for a different display within a session. It SHOULD give
the same display the same identifier in every session, for example by deriving it from the
display's hardware identity, so that a client can ask for it again when it next connects.

### DISPLAYS

`DISPLAYS` is a control message from host to client on stream 0 ([control.md](control.md)). It
lists every display the host can stream and replaces whatever list the client held.

A host MUST send `DISPLAYS`:

- as the first control message of a session;
- after a resume, and after it takes a session over ([handshake.md](handshake.md#taking-over-a-session));
- whenever a display is added or removed, or changes its mode, its place in the layout or its name.

> **Why a complete list every time.** Displays change rarely and the list is small. A client that
> replaces its list wholesale never has to reconcile an update against what it holds, and a
> message lost to a park is made good by the next one.

> **Why after the handshake.** A `RESPONSE` can be no larger than its `INIT`, which can be as
> small as 256 bytes ([gaps.md](gaps.md#the-smallest-datagram)). A list of displays with their
> names doesn't belong in it. Nothing needs the list before the first frame: the host binds a
> display on its own when the client names none ([below](#binding-a-stream-to-a-display)).

## Video streams

The stream table is fixed for the life of a session ([handshake.md](handshake.md#stream_table-4)),
so a client proposes, when it connects, one `VIDEO` stream for every display it might show at
once, as it does for gamepads ([input.md](input.md#splitting-input-by-device)).

A host SHOULD accept every video stream the client proposes. The protocol sets no limit on how
many displays a session streams at once, beyond the stream table's own; the host's hardware sets
it. A host finds its limit by trying: it refuses a binding whose capture or encoder it cannot
start ([below](#binding-a-stream-to-a-display)), and unbinds a stream whose capture or encoder
fails later ([When displays change](#when-displays-change)). A stream in the table that shows
nothing costs nothing: no capture, no encoder, no frames.

> **Why no declared limit.** How many streams a host can encode depends on the resolutions and
> frame rates asked for, on what else the encoder is doing, and on the machine, so any number
> declared in advance is wrong in one direction or the other. Trying costs one refused setting.

### Binding a stream to a display

Each video stream shows one display, or none. Which one is a setting of that stream, `DISPLAY`,
holding a `display_id` or 0 for none. It is set and reported like the stream's other settings
([modes.md](modes.md)): the client asks, the host applies what it can and reports what it applied.

When a session starts:

- A client MAY bind its video streams in the `SETTINGS` of its `INIT`, naming identifiers from an
  earlier session. The host binds each one it can. An identifier it does not know leaves that
  stream showing nothing.
- If the client binds none, the host binds the first `VIDEO` stream of the table to its primary
  display and leaves the others showing nothing.

> **Why the host binds the primary display on its own.** A client that knows nothing about the
> host's displays, on its first connection or because it doesn't care, gets a picture one round
> trip after it asks, as it would with a host that had only one display. Asking for the list
> first and binding afterwards would cost a second round trip on every connection.

A client MAY change a stream's display at any time. The first frame the host sends on that
stream afterwards MUST be an IDR with its own `CODEC_CONFIG`, in a new `config_generation` of that
stream ([video.md](video.md)). Binding a stream to 0 stops its frames; the host MAY release its
capture and encoder, and the client its decoder.

Two streams MAY show the same display, each encoded with its own settings: one full size on a
large screen and one scaled down, for example. A host that cannot do this, or cannot bind a
stream for any other reason, refuses the setting the way it refuses any setting, and the stream
keeps the display it had.

A host MUST report the display each stream shows whenever it changes, including when the host
changes it itself, as it does when a display goes away ([below](#when-displays-change)).

## Each stream is independent

Everything about a video stream belongs to that stream alone:

- its `frame_id` sequence and its `config_generation`;
- its settings: the display, the resolution and scaling, the frame rate, the chroma format, HDR,
  and its share of the rate;
- its capture and encoder on the host, and its decoder on the client;
- its retransmission store, its reassembly, its `NACK`s, and its refresh attempts and their
  `req_id`s ([feedback.md](feedback.md));
- its long-term references and its reference epoch;
- whether it is suspended ([session.md](session.md)).

A keyframe, a change of settings, a loss, a recovery, a stall or a suspension on one video stream
MUST NOT change anything on another. In particular:

- A receiver MUST deliver each stream's frames as they become deliverable, without waiting for,
  or being held behind, another stream.
- A host MUST NOT produce an IDR on one stream because of an event on another.
- A client MUST ask for repair, and for recovery frames, on the stream that needs them.

The streams are not synchronised with one another. Every frame's `capture_time_us` comes from the
same monotonic clock on the host ([packets.md](packets.md#clocks)), so a client that wants to
present several displays in step MAY use it to align them.

> **Why fully independent.** A client usually shows each display in its own window, often on its
> own screen. Coupling the streams in any way, a shared keyframe, a shared reference chain or a
> shared delivery order, turns one display's lost packet into a freeze on all of them, and
> charges a keyframe to displays that needed none. Most of the machinery is already per stream,
> because the chunks that carry and repair media name their stream
> ([packets.md](packets.md#streams)). This section makes the separation a requirement rather than
> a consequence.

## What a session has once

Everything that is not a video stream belongs to the session, however many displays it shows:

- **The transport.** One set of keys and packet numbers, one `FEEDBACK` report, one round-trip
  estimate, one peer address.
- **The rate.** Rate control ([rate-control.md](rate-control.md)) chooses one rate for the path
  and divides it among the video streams that show a display, after audio has what it needs. The
  client MAY give each video stream a weight; by default each stream's share is proportional to
  its pixel rate, width × height × frame rate.
- **Pacing.** One pacer for the whole session. A sender SHOULD interleave the video streams'
  fragments by weight rather than send one stream's backlog before another's, so that a keyframe
  on one display does not push another display's frames past their deadlines.
- **Audio.** One audio stream: the host's system audio, mixed, whichever displays are shown.
- **Input.** One keyboard, whose input goes wherever the host's focus is; one pointer, over the
  host's whole desktop; the gamepads; the microphone.
- **The cursor.** One cursor, on one display at a time.
- **The lifecycle.** A session parks, resumes, is taken over and ends as a whole.

## The pointer and the cursor

An absolute pointer position names the display it is on: a `display_id`, and a position
normalised to that display's full area, 0 being its left or top edge and 65535 its right or bottom
edge. A client computes it from whichever of its windows the pointer is over, using the display
that window's stream shows. A host MUST ignore a position on a display it does not have.

> **Why the display and not the stream.** Two streams can show the same display, and the pointer
> lives in the host's desktop, not in any stream. Naming the display gives the host a position it
> can act on directly, and gives the client a message that means the same thing whichever window
> it came from.

Relative pointer motion moves the host's pointer across its desktop as a local mouse would, which
can take it onto a display the client is not showing.

The cursor channel from host to client names the display the cursor is on. A client draws the
cursor only over the streams that show that display.

## When displays change

| Change on the host | What the host does |
|---|---|
| A display is added | Sends `DISPLAYS`. Nothing is bound to it until the client asks |
| A display is removed | Sends `DISPLAYS`, unbinds every stream that showed it, and reports each one |
| A display's mode changes: its resolution, scale, HDR or rotation | Sends `DISPLAYS`, and on every stream that shows it sends an IDR with its own `CODEC_CONFIG` in a new `config_generation`. Streams showing other displays see nothing |
| A display moves in the layout, or is renamed | Sends `DISPLAYS`. No keyframe |
| A stream's capture or encoder fails | Unbinds that stream and reports it. The others carry on |

A client whose stream was unbound keeps the last picture it decoded, and MAY bind the stream to
another display.

## Parking and resuming

A session parks and resumes as a whole ([session.md](session.md)). The display each stream shows
survives a park and a take-over.

`RESUME` reports, for each video stream, whether its decoder survived and which frame it last
decoded. The host answers each stream on its own: a stream whose decoder still holds a usable
reference can continue from it, and a stream whose decoder is gone gets an IDR. A display removed
while the session was parked comes back unbound, and the host reports it with the `DISPLAYS` it
sends after the resume.

Suspending video is per stream. A client that hides one display's window suspends that stream
alone, and the others carry on.

A host that keeps its capture and encoders warm through a park ([session.md](session.md)) keeps
them for every stream that shows a display, as far as its own limits allow.

## Where the bytes go

| What | Defined in |
|---|---|
| `DISPLAYS` and the display descriptor | [control.md](control.md) |
| The `DISPLAY` setting, each stream's weight and other per-stream settings, and bindings in the `INIT`'s `SETTINGS` | [modes.md](modes.md) and [control.md](control.md) |
| The display in an absolute pointer position and in the cursor's position | [input.md](input.md) |
| Each video stream's decoder state in `RESUME` | [session.md](session.md) |
| How the rate is divided among the streams | [rate-control.md](rate-control.md) |

Streaming a single window or a region, displays the host creates for a client, and audio per
display are not part of version 1; see [gaps.md](gaps.md#windows-regions-and-virtual-displays).
