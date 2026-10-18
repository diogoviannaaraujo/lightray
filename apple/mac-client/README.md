# Lightray for macOS

Lightray is the client: it connects to host devices, displays their streams, and sends input.
Install [Lightray Host](../mac-host/README.md) separately on a Mac you want to share.

## Build and install

Requires macOS 27 and Swift 6.4. From the repository root:

```bash
swift test --package-path apple/mac-client
swift build -c release --package-path apple/mac-client
python3 apple/scripts/package-app.py --app client
```

Copy `apple/.build/apps/Lightray.app` to Applications from `Lightray-0.1.0-arm64.dmg`.
The app contains no host helper and never enables sharing on this Mac.
Quit the old Lightray app before replacing it. Its bundle identifier is `com.getlightray.client`,
shared with the iPad app. Builds before the rename used `io.lightray.mac`: pairing files carry over,
but saved computers and session preferences stay under the old identifier until copied once with
`defaults export io.lightray.mac - | defaults import com.getlightray.client -`.
Closing its last window keeps the Dock app available; clicking its icon reopens it.
Quitting the client disconnects its remote session and has no effect on a local host service.

See the [Apple build and release guide](../README.md) for signing and release artifacts.

### Command-line launcher

Start `apple/mac-client/.build/release/lightray-client` without a host to open the SwiftUI Paired Hosts list.
Choose **Add Host** (⌘N), enter a hostname/IP and optional name, paste the host’s pairing code or
import its pairing file, and choose a local display. **Add Host** saves the host to the list;
**Connect** on its row starts a session. Each host’s menu offers **Edit Host** and **Forget Host**.
Public metadata is stored separately from the protected pairing file. Hosts are kept only for
the current run when the catalog is disabled or could not be loaded.
The session menu offers Disconnect, which returns to the host list; closing the last stream does the same in this mode.
The launcher returns to the host list with guidance if authentication does not succeed within 12 seconds after network setup.
`--launcher` forces this mode with optional CLI defaults; `--no-host-catalog --no-preferences` isolates laboratory runs from saved hosts/settings.
Monitor preferences use persistent display UUIDs, with an available-display fallback after disconnection.
The [connection and WGC validation report](https://github.com/diogoviannaaraujo/lightray/blob/5ae52d6/docs/windows/connection-capture-progress-2026-10-01.md), kept at the commit that added it, records the tested behavior and the open onboarding and compatibility gates.

## Connect from the command line

```bash
apple/mac-client/.build/release/lightray-client host.example --pair lr1-…
```

Import the pairing supplied by the host once; the client remembers it. Keys go to the remote
host, including Command shortcuts except those reserved by macOS. **⌃⌥⌘Q quits the client.**
Each window displays one host display. Use the Displays menu to open or switch displays;
`--all-displays` opens all of them, subject to the `--streams` limit (default 4).
Closing the last stream returns to the host list in launcher mode and quits in direct CLI mode.

### Options

| Client | |
|---|---|
| `host[:port]` | Name or address; `[::1]:7373` for IPv6 with a port |
| `--pair TOKEN` | Use and remember a pairing token |
| `--pair-file FILE` | Use the token in a file for this run, without saving it or showing it in the arguments |
| `--launcher` | Open the host list instead of connecting; the default with no host |
| `--no-host-catalog` | Do not load or save remembered computers |
| `--no-preferences` | Ignore saved session preferences and save none during this run |
| `--stats`, `--no-stats` | Show or hide the statistics overlay at start |
| `--swap-command-control`, `--physical-keys` | Send Command as Control and Control as the Windows key, or keys as they are |
| `--local-cursor`, `--host-cursor` | Show a local pointer over the video, or hide it |
| `--screen-id N` | Open the stream windows on this Mac display |
| `--mtu N` | Datagram size to propose, default 1200 |
| `--streams N` | Video streams to propose: how many displays can be shown at once, default 4 |
| `--all-displays` | Show every display of the host at start |
| `--show ID` | Show that display at start; repeat for more windows |
| `--drop-rate X` | Drop a fraction X of arriving datagrams |
| `--snapshot FILE` | Write each stream's picture to a PNG 3 s after its first; streams after the first add `-<stream>` to the name |
| `--exit-after S` | Quit after S seconds |
| `--no-fec` | Do not offer FEC; the host then sends no parity |


## Session controls and host preferences

Each window shows a statistics overlay: the stream's resolution and state, the client's decode and
queue times, the round-trip time, and, from a host that sends the
[timing extension](#provisional-host-timing-extension), its capture and encode times. ⌃⌥⌘M
toggles it. For Windows hosts, `--swap-command-control` or the Input menu sends Command as Control,
so that Command-C and Command-V copy and paste there. ⌃⌥⌘Esc releases remote input; a click on the
video resumes it.

The client exposes a Lightray session button in windowed and full-screen mode, also available through View → Session Menu or Control+Option+Command+S.
Opening it releases remote input; closing it keeps input released until explicit resume or a consumed click on the video.
The panel offers statistics, optional Command/Control swapping, local pointer, full screen, Alt+Tab, Windows key and preference reset.
Remote actions require live decoded video; waiting or interrupted video cannot forward input.
The cursor remains visible locally while input cannot be forwarded.

Preferences persist by public pairing ID and contain no pairing key or clipboard data.
Explicit CLI choices override the initial saved values without saving them at launch: `--stats`/`--no-stats`, `--physical-keys`/`--swap-command-control`, and `--host-cursor`/`--local-cursor`.
Use `--no-preferences` to isolate a lab run and `--screen-id N` to select a local presentation monitor after checking the current screen inventory.
Successful decodes drive a local waiting/live/interrupted state; two seconds without progress after live video pause input, without attributing the cause to capture or network.
The [implementation, evidence and remaining validation](https://github.com/diogoviannaaraujo/lightray/blob/5ae52d6/docs/windows/session-controls-progress.md) and the [telemetry semantics](https://github.com/diogoviannaaraujo/lightray/blob/5ae52d6/docs/windows/host-telemetry-progress.md) are kept at the commit that added them.

See the core README for [implementation status](../core/README.md#what-is-implemented) and [remaining protocol features](../core/README.md#not-yet).
