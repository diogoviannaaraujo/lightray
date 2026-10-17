# Lightray Host for macOS

Lightray Host shares this Mac. It is installed separately from the [Lightray client](../mac-client/README.md).
Requires macOS 27 and Swift 6.4.

## Build and install

From the repository root:

```bash
swift test --package-path apple/mac-host
swift build -c release --package-path apple/mac-host
python3 apple/scripts/package-app.py --app host
```

Copy `apple/.build/apps/Lightray Host.app` to Applications from `LightrayHost-0.1.0-arm64.dmg`.
Quit the old combined Lightray app first so its host releases the UDP port and capture resources.
Existing host pairing is preserved. Host settings are imported once from the old app, with sharing
initially disabled. The client and host need no terminal or web runtime.

## Sharing and login

Open Lightray Host, choose the port, quality, and keyboard/mouse access, then **Start Sharing**.
The default is port 7373 and Balanced quality (half resolution, 30 fps). Start Sharing registers
the per-user background service immediately and at subsequent logins. Approve background activity
in **System Settings → Login Items & Extensions** if requested.

Use **Screen Recording…** and **Accessibility…** to grant permissions to the service that actually
captures and injects input. macOS may list Screen Recording under **Lightray Host** and
Accessibility under **LightrayHostService**. Start Sharing first so that process is available. Accessibility is
optional when keyboard/mouse control is disabled. The UI reports the service's permissions;
permissions previously granted to the old combined app may need to be granted again.
After changing permissions, use **Retry Sharing** if macOS requires a fresh process.
Permission prompts occur only during explicit setup, not automatically at login.

The background service owns the menu bar indicator. It opens no window or Dock icon at login.
**Open Host Settings…** reopens the settings app. Closing or quitting either Lightray or Lightray
Host leaves sharing available. **Stop Sharing** shuts down streaming and unregisters the service;
sharing stays off across app restarts and logins until explicitly started again.

A crash restarts the service with launchd throttling. Missing permissions, configuration errors,
and occupied ports appear as blocked/failed status. An approved service is re-registered when the
Host app opens after an upgrade; approval revoked in System Settings is never silently restored.
Before removing the Host app, choose Stop Sharing to unregister it.

The service runs in the logged-in graphical user session. It provides no pre-login access and
installs no root daemon. Its label and Mach service are `com.getlightray.host.service`.
Settings live in `~/Library/Application Support/Lightray/Host/settings.json` (private directory,
owner-only file); pairing remains in `~/Library/Application Support/Lightray/host-pairing`.
**Show Host Log** opens `~/Library/Logs/Lightray/host.log`; the previous oversized log is retained.
Never share pairing codes or files publicly: they authorize remote control.

Use **Copy Pairing Code** or **Export Pairing File…** to authorize a Mac or iPad client.
Service registration state and actual streaming readiness are reported separately.

## Standalone command-line host

The CLI does not install or modify a login service. Create pairing once, then run:

```bash
apple/mac-host/.build/release/lightray-host pair
apple/mac-host/.build/release/lightray-host
```

For a permission-free synthetic stream:

```bash
apple/mac-host/.build/release/lightray-host --test-pattern 1280x720 --log-input
```

A real desktop requires Screen Recording and Accessibility access for the process launching the
CLI, such as Terminal. Allow the screen-picker bypass confirmation when macOS requests it.
Do not run the CLI on the service's port. macOS permits only one capturing process per executable
file; copy the executable when intentionally testing multiple hosts.

### Options

| Host | |
|---|---|
| `--port N` | UDP port, default 7373 |
| `--fps N` | Frame rate cap, default 60 |
| `--bitrate N` | Video bitrate in Mb/s for each display shown, parity included, default 20 |
| `--scale X` | Capture at X times each display's pixel size |
| `--mtu N` | Largest datagram accepted, default 1200 |
| `--log-input` | Log input messages instead of injecting them |
| `--no-input` | Ignore input |
| `--test-pattern WxH` | Offer two synthetic displays of that size instead of the real ones; needs no permission |
| `--warm S` | Idle capture timeout in seconds, default unlimited; 0 disables prewarming; `inf` keeps it ready indefinitely |
| `--fec PERCENT` | Reed–Solomon parity per block of fragments, for clients that offer FEC; 0 turns it off. Default 10 |
| `--fec-min N` | At least N parity fragments per block, default 1. `--fec 20 --fec-min 2` is Sunshine's setting |
| `--drop-rate X` | Drop a fraction X of arriving datagrams |

### Capture lifecycle

The host prepares its primary display's capture and encoder before accepting connections and
keeps capture and encoders ready indefinitely by default. Connecting or resuming immediately
encodes the latest captured picture as a keyframe, even when the desktop has not changed.
Encoding pauses without a client; while connected, a still picture is refreshed about once a
second so that it stays live on the client. `--warm S` opts into an idle timeout, including
before the first connection; `--warm 0` disables prewarming and releases capture on disconnect.
Keeping capture ready uses more idle resources than releasing it. When a
display is unplugged, the windows showing it close; when its resolution changes, they get a
keyframe of the new size. When the host's capture stops on its own (macOS reconfigured the
display: a Screen Sharing session that added a virtual display ended, say), the host starts it
again, retrying every 2 s at most while it fails, and the window carries on. If the host stops
showing the last window's display because that display went away, the window moves to the
primary display; otherwise it stays open and says so, rather than the client seeming to quit.
The host uses its cached display list immediately at session start, refreshes it in the
background, and checks for display changes every second, since
macOS does not always announce a change: a Screen Sharing session in its high-performance mode
replaces the displays with a virtual one while it lasts, and takes it away when it ends.

## Implementation

`LightrayHostRuntime` owns capture, encoding, input, and the host endpoint. `LightrayHostSupport`
contains versioned settings, service registration, and authenticated XPC interfaces.
`lightray-host-app` is the settings UI; `lightray-host --service` is the bundled accessory agent.
The service uses its own permission state and runs independently of the settings app.

See [protocol implementation status](../core/README.md#what-is-implemented),
[provisional formats](../core/README.md#provisional-input-format), and
[remaining features](../core/README.md#not-yet). See the [Apple guide](../README.md) for release
packaging and the installed-service acceptance checklist.
