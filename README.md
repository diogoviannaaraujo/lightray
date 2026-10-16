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

## Applications

On **macOS and Windows, the host and client must be separate applications**, installed and run
independently. A computer can have either app or both, depending on whether it shares its desktop,
connects to other devices, or does both.

| Application | Responsibility |
|---|---|
| **Host** (macOS and Windows) | Installs and manages its own background service, which starts sharing automatically when the user logs in. The host app provides sharing settings, permissions, pairing, and service controls |
| **Client** (macOS, Windows, and iOS/iPadOS) | Connects to host devices, displays their streams, and sends the user's input. It manages saved devices, pairing credentials, and remote sessions |

Sharing belongs to the host service's lifecycle. Closing the host's settings window or quitting
the client must leave sharing available; stopping sharing is an explicit host control. The client
must not bundle, start, or manage a local host. iOS/iPadOS has a client only.

On macOS, install **Lightray** to connect to devices and **Lightray Host** to share this Mac.
Start Sharing enables the host service now and at login; Stop Sharing keeps it off until explicitly
started again. The [Windows applications](windows/README.md) follow the same model, with a
current-user login agent and separate WinUI 3 interfaces.

## Layout

All Apple projects live under `apple/`, with the shared core and each app in its own directory:

```text
apple/
├── core/         # LightrayCore: shared protocol, transport, and media support
├── mac-client/   # macOS app for connecting to host devices
├── mac-host/     # macOS host app and its background sharing service
└── ios-client/   # iOS/iPadOS client app
```

Each Apple app depends on `core/`; the apps remain separate projects. The macOS host owns service
installation, startup at login, capture, and input injection. The clients own connection and
session UI. Windows follows the same host/client separation, outside the Apple directory.

Repository directories:

| Directory | What it holds |
|---|---|
| [`docs/`](docs/README.md) | The protocol specification. When it is finished it will be complete enough to build a conforming host or client from, in any language, without reference to any code here |
| [`notes/`](notes/README.md) | Measured platform behaviour that implementations depend on, and the evidence behind the protocol's defaults |
| [`tools/vectors/`](tools/vectors/README.md) | The generator of every hex example in `docs/` and of `vectors.json`, the file to test an implementation against. It also checks the links in `docs/` |
| [`apple/`](apple/README.md) | Apple build, packaging, and release guide |
| [`apple/core/`](apple/core/README.md) | `LightrayCore`: shared protocol, transport, pairing, and media support |
| [`apple/mac-client/`](apple/mac-client/README.md) | Lightray client app and `lightray-client` executable |
| [`apple/mac-host/`](apple/mac-host/README.md) | Lightray Host settings app, login service, and `lightray-host` executable |
| [`apple/ios-client/`](apple/ios-client/README.md) | Native SwiftUI iPadOS 27 client using the shared core |
| [`windows/`](windows/README.md) | Separate Windows host and client, a shared portable Rust core, native NVIDIA/D3D11 media backends, WinUI 3 interfaces, tests, and packaging |
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
  [`apple/core/README.md`](apple/core/README.md#what-is-implemented). They are the implementation's, not
  the protocol's, and will change as the documents are rewritten.
- **The packages refer to each other by path.** All Apple apps depend on `apple/core/`, whose
  tests read `tools/vectors/vectors.json`; `lightray-vectors` checks `docs/`. Build from a whole
  checkout.

## Status

- **The specification.** Version 1 is being written over version 0, one document at a time. The
  [reading map](docs/README.md#how-to-read-this-directory) gives the state of each document, and
  [`gaps.md`](docs/gaps.md) what version 1 leaves unresolved.
- **macOS.** The host and client work Mac to Mac: video from any number of the host's displays,
  and keyboard and mouse back. The client and host have separate app bundles. The host registers an independent
  sharing service for the logged-in user. The core README lists
  [what they implement](apple/core/README.md#what-is-implemented) and
  [what they do not yet](apple/core/README.md#not-yet).
- **iPad.** The proof of concept in [`apple/ios-client/`](apple/ios-client/README.md) connects to the Mac host, streams one
  display at a time, sends touch, pointer and hardware-keyboard input, and reconnects when returning
  from the background. It targets iPadOS 27 and shares `apple/core/` with the Mac apps.
- **Windows.** The implementation in [`windows/`](windows/README.md) uses shared Rust protocol/media
  engines and separate C# WinUI 3 applications. The initial target is Windows 11 x64 with NVIDIA,
  SDR HEVC, and a 1080p60 baseline. Hardware loopback and Apple fixtures are tested locally;
  Mac-to-Windows LAN acceptance remains pending. The historical laboratory in `tools/windows/`
  still depends on the obsolete Swift bridge and remains research material.

## Build and test

The Apple packages need macOS 27 and Swift 6.4; `tools/vectors/` needs macOS and Swift 6. From the root of the checkout:

```bash
swift test --package-path apple/core
swift test --package-path apple/mac-host
swift build -c release --package-path apple/mac-client
swift build -c release --package-path apple/mac-host
swift run --package-path tools/vectors lightray-vectors check
```

These run the core and host tests, build the two command-line apps in their respective
`.build/release/` directories, and check the protocol examples and links. The
[Apple guide](apple/README.md) covers separate app/DMG packaging, signing, releases, and
installed-service acceptance. Each project README covers its own setup and permissions.

## What main keeps

Main keeps what someone needs to implement a host or a client, on any platform. Research is
distilled into [`notes/`](notes/README.md); the raw material behind it, and reports of work in
progress, stay in the history and are linked by commit.

| Commit | What it holds |
|---|---|
| `b582e73` | The whole version 0 specification, before version 1 began to replace it |
| `3cf4c28` | The probes, the simulator and their raw output, behind [`notes/`](notes/README.md) |
| `5ae52d6` | Pull request #3 as submitted, with the Windows reports and evidence that [`tools/windows/`](tools/windows/README.md) and [`Apple apps`](apple/README.md) link to |

To look at one without disturbing a checkout:

```bash
git worktree add ../lightray-research 3cf4c28
```

The Windows validation brief that [`gaps.md`](docs/gaps.md) cites, `tools/windows/BRIEF.md`, is
on the `windows-validation` branch.
