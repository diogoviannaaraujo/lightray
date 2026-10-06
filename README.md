# Lightray

Lightray is a UDP protocol for low-latency interactive streaming. One machine, the **host**,
sends encoded video and audio to another, the **client**, and the client sends back input. It is
built for a person controlling what they are watching, and for **session continuity**: a client
that goes away, because its app was sent to the background, its lid closed or its network
dropped for a moment, comes back to the same session in about one round trip and one frame.

Its defaults are tuned for playing games on a Mac from a Windows host over a LAN, using one Mac
from another over the internet, and using a Mac from an iPad over the internet.

This repository holds the protocol's specification, the measurements behind it, the tool that
generates and checks its examples, and its implementations.

## Layout

| Directory | What it holds |
|---|---|
| [`docs/`](docs/README.md) | The protocol specification. When it is finished it will be complete enough to build a conforming host or client from, in any language, without reference to any code here |
| [`notes/`](notes/README.md) | Measured platform behaviour that implementations depend on, and the evidence behind the protocol's defaults |
| [`tools/vectors/`](tools/vectors/README.md) | The generator of every hex example in `docs/` and of `vectors.json`, the file to test an implementation against. It also checks the links in `docs/` |
| [`apple/`](apple/README.md) | `LightrayCore`, the Swift package the apps share on macOS and iOS: the protocol, with no I/O, and what an app needs around it: the UDP socket, pairing, the VideoToolbox encoder and decoder, a renderer, and `ClientRunner`, which runs a client |
| [`macos/`](macos/README.md) | The Mac host and client, `lightray-host` and `lightray-client` |
| [`ios/`](ios/README.md) | The iPadOS 27 client proof of concept: a native SwiftUI app using the shared Apple core |
| [`tools/windows/`](tools/windows/README.md) | The Windows laboratory from pull request #3: a C++ host that captures with DXGI or Windows Graphics Capture, encodes with NVENC and injects input, and the probes and scripts around it |

How the parts fit together:

- **`docs/` is the reference.** The notes explain its defaults; where a note and `docs/`
  disagree, `docs/` wins.
- **No example in `docs/` is written by hand.** `tools/vectors/` works each one through both
  sides of the protocol from fixed inputs, so a document cannot show bytes that one side would
  produce and the other reject.
- **The Apple implementation fills in what version 1 has not yet written.** Where it needs bytes
  the specification does not define yet, such as the input payloads and the messages that choose
  a display, it uses provisional formats of its own, defined in
  [`macos/README.md`](macos/README.md#what-is-implemented). They are the implementation's, not
  the protocol's, and will change as the documents are rewritten.
- **The packages refer to each other by path.** `macos/` builds on `apple/`, `apple/`'s tests
  read `tools/vectors/vectors.json`, and `lightray-vectors` checks `docs/`. Build them from a
  whole checkout.

## Status

- **The specification.** Version 1 is being written over version 0, one document at a time. The
  [reading map](docs/README.md#how-to-read-this-directory) gives the state of each document, and
  [`gaps.md`](docs/gaps.md) what version 1 leaves unresolved.
- **macOS.** The host and client work Mac to Mac: video from any number of the host's displays,
  and keyboard and mouse back. Their README lists
  [what they implement](macos/README.md#what-is-implemented) and
  [what they do not yet](macos/README.md#not-yet).
- **iPad.** The proof of concept in [`ios/`](ios/README.md) connects to the Mac host, streams one
  display at a time, sends touch, pointer and hardware-keyboard input, and reconnects when returning
  from the background. It targets iPadOS 27 and shares `apple/` with the Mac apps.
- **Windows.** The laboratory host does not build on main, and nothing in `tools/windows/` is
  maintained. It took its protocol layer from the Swift package, which is now for Apple platforms
  only. Windows is to be ported to Rust.

## Build and test

`apple/` and `macos/` need macOS 27 and Swift 6.4; `tools/vectors/` needs macOS and Swift 6. From
the root of the checkout:

```bash
swift test --package-path apple
swift build -c release --package-path macos
swift run --package-path tools/vectors lightray-vectors check
```

The first runs the shared package's tests. The second builds the two apps into
`macos/.build/release/`. The third checks that every example and link in `docs/` is current;
run it before committing a change there. Each directory's README has the rest: running the apps
and the permissions the host needs, building for iOS, and regenerating the examples.

## What main keeps

Main keeps what someone needs to implement a host or a client, on any platform. Research is
distilled into [`notes/`](notes/README.md); the raw material behind it, and reports of work in
progress, stay in the history and are linked by commit.

| Commit | What it holds |
|---|---|
| `b582e73` | The whole version 0 specification, before version 1 began to replace it |
| `3cf4c28` | The probes, the simulator and their raw output, behind [`notes/`](notes/README.md) |
| `5ae52d6` | Pull request #3 as submitted, with the Windows reports and evidence that [`tools/windows/`](tools/windows/README.md) and [`macos/`](macos/README.md) link to |

To look at one without disturbing a checkout:

```bash
git worktree add ../lightray-research 3cf4c28
```

The Windows validation brief that [`gaps.md`](docs/gaps.md) cites, `tools/windows/BRIEF.md`, is
on the `windows-validation` branch.
