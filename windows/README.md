# Lightray for Windows

Two independent Windows 11 x64 applications, with Rust protocol and media engines and C# WinUI 3 interfaces:

- **Lightray Host** shares this PC. Its Rust agent owns capture, encoding, networking, and input. Closing the settings app leaves enabled sharing running.
- **Lightray Client** connects to another host. It never starts, installs, or manages a local host.

The initial hardware target is NVIDIA, tested on an RTX 4090. The baseline is 1920×1080 at 60 fps, SDR HEVC Main. Higher stream sizes are available but are not performance guarantees. The Apple applications remain Swift projects under `apple/`.

## Build and package

Install Rust 1.98.0 with the MSVC target, Visual Studio Build Tools with C++ tools and Windows SDK 10.0.26100.0, and .NET SDK 10.0.203. NuGet and Cargo network access are needed on the first build. The projects lock native and managed dependencies and use Windows App SDK 2.5.1.

From the repository root, in PowerShell:

```powershell
./windows/scripts/Build.ps1
```

This runs formatting checks, Clippy, portable/platform/runtime tests, a release build, a native ABI lifecycle check, and self-contained publishing. It produces two separate bundles and SHA-256 files:

```text
windows/artifacts/Lightray-Host-win-x64.zip
windows/artifacts/Lightray-Client-win-x64.zip
```

`-SmokeTest` additionally starts each WinUI application with isolated settings and verifies its automatic five-second shutdown. It requires an interactive Windows desktop. The CI workflow builds both bundles; GPU and desktop checks are local hardware tests. Pushing a `vMAJOR.MINOR.PATCH` tag runs the [release workflow](../.github/workflows/release.yml), which attaches `Lightray-Host-VERSION-win-x64.zip` and `Lightray-Client-VERSION-win-x64.zip` to the draft release. The workspace version in `Cargo.toml` must match the tag.

For a quicker development build:

```powershell
cargo build --manifest-path windows/Cargo.toml --release --locked
dotnet build windows/ui/Host/Lightray.Host.csproj -c Release -p:RestoreLockedMode=true
dotnet build windows/ui/Client/Lightray.Client.csproj -c Release -p:RestoreLockedMode=true
```

The managed build copies the release Rust DLL alongside the executable. Host builds also copy the agent. Prefer the published bundles when testing an installation: all .NET and WinUI runtime files must remain beside the app.

## Install and run

Extract each desired bundle, then run its `Install.ps1`. Installation is per user, under `%LOCALAPPDATA%\Programs\LightrayHost` or `LightrayClient`, with separate Start menu shortcuts. Installing the client alone installs no sharing agent. Installing the host does not enable sharing.

Open **Lightray Host**, select the port, frame rate, bitrate, maximum resolution, and keyboard/mouse access, then choose **Start Sharing**. This starts the agent and registers its current-user login task. **Stop Sharing** stops it and removes login startup. **Apply Settings** restarts the active pipeline; connected clients reconnect. Copy or export a pairing code for the client.

The agent runs in the signed-in desktop session, rather than as a Session 0 system service. Desktop lock or loss of access pauses media and releases held input. There is no pre-login, secure-desktop, or elevated-application control. Windows Graphics Capture provides the system capture indicator and includes the cursor.

For another machine to connect, allow the installed `lightray-host-agent.exe` through Windows Firewall on the private LAN profile when Windows prompts. The default is UDP 7373. The app does not silently modify firewall rules. If no prompt appears, add an inbound private-profile rule for that executable and port through Windows Security.

Open **Lightray Client**, enter the host/IP (including an optional port), import the pairing file, and connect. Remembered computers store public metadata separately from the DPAPI-protected pairing code. One streaming window represents one negotiated display stream; the session menu can open another display or move the current stream.

The stream controls offer fullscreen, statistics, local cursor visibility, physical or swapped Control/Command keys, and committed Unicode text. **Ctrl+Alt+Shift+F12** releases remote input. Opening controls or losing focus also releases held keys and buttons. Use **Resume input** or click the video to resume while live video is available. Shortcuts Windows reserves for itself remain local.

The Windows client requires a D3D11-aware hardware HEVC decoder, normally supplied by **Microsoft HEVC Video Extensions**, plus a compatible graphics driver. The client reports an unavailable decoder explicitly; it does not fall back to software decoding.

Run the installed bundle's `Uninstall.ps1` to stop its processes, remove its shortcut and, for Host, remove its login task. Settings and credentials are preserved by default. `-RemoveUserData` explicitly removes that application's saved data. Upgrading through `Install.ps1` stops the old agent before replacing files and leaves sharing disabled until explicitly started again.

## Architecture and compatibility

| Component | Responsibility |
|---|---|
| `core` / `lightray-core` | Portable, sans-I/O endpoints; Noise handshake; encrypted datagrams; replay/rebind rules; reliable streams; feedback; HEVC framing; exact-profile Reed–Solomon FEC; pacing and recovery; display/input messages |
| `platform` / `lightray-windows` | NVIDIA display inventory, Windows Graphics Capture, D3D11 conversion, native dynamically loaded NVENC, hardware Media Foundation decoding, GPU composition swap chains, input injection, and DPAPI |
| `runtime` / `lightray-runtime` | UDP loops, bounded capture workers, shared DLL ABI, credential/settings persistence, current-user named-pipe control, and login-agent management |
| `ui` | Separate WinUI 3 host and client applications; no protocol or codec implementation |

The ABI is declared in `runtime/include/lightray.h`. Opaque handles have explicit lifetimes. JSON commands/events are copied, queues are bounded, and Rust panics are contained at the boundary. Rust owns GPU devices and swap chains; C# attaches an AddRef'd chain on the UI thread, releases the temporary reference, and detaches the panel before destroying the engine. Native video never passes through a managed bitmap.

The wire target is the existing Apple implementation at `2aac433`: version 1 handshake/packets and the provisional video, FEC, display-control and input formats in `apple/core/README.md`. It uses the existing `lr1-` pairing token, UDP 7373, MTU 1200, fixed 10% FEC with at least one parity shard per block, reliable keyboard/pointer streams, and FEC → retransmission → IDR recovery. Multiple display streams recover independently. The host accepts one client session at a time.

Defaults are 60 fps, a 1920×1080 maximum preserving display aspect, and 20 Mb/s per display including parity. NVIDIA-attached displays are advertised. The encoder receives the bitrate after reserving parity overhead. Capture is prepared while idle; encoding pauses without a client. Static desktops retain a cached frame for immediate IDR and periodic refresh.

The pure core receives explicit monotonic and wall-clock time and returns events, outbound datagrams with their destinations, and timer deadlines. It does not depend on WinUI, sockets, codecs, or Windows. Protocol examples and FEC fixtures are consumed directly from the existing repository, not copied into a separate Windows fixture collection.

Credentials/settings are under `%LOCALAPPDATA%\Lightray\Host` and `Client`; logs are under `Logs`. Pairing and reset secrets use user-scoped DPAPI. The local control pipe rejects remote clients, uses a current-user DACL, and checks the connecting process's desktop session. `LIGHTRAY_DATA_DIR` redirects these files for isolated tests. Pairing codes must not be included in reports or logs.

## Validation

Portable/ordinary Windows checks do not capture the desktop or inject input:

```powershell
cargo test --manifest-path windows/Cargo.toml --workspace --locked
cargo clippy --manifest-path windows/Cargo.toml --workspace --all-targets --locked -- -D warnings
windows/target/release/lightray-check.exe --abi-smoke
```

`lightray-check.exe --service-smoke` is an opt-in interactive acceptance check of Start Sharing, current-user login registration, agent survival after the settings handle closes, and Stop Sharing. It uses isolated settings and synthetic video with input disabled, refuses to run over an existing host/task, and removes its own task/agent afterward. It leaves its report under `windows/target/acceptance`.

The hardware validator generates a moving 1080p pattern, encodes with NVENC, sends it through authenticated host/client endpoints over real local UDP sockets, and hardware-decodes/presents the resulting frames:

```powershell
windows/target/release/lightray-check.exe --seconds 10
windows/target/release/lightray-check.exe --seconds 10 --loss 5 --seed 1
windows/target/release/lightray-check.exe --seconds 600
cargo test --manifest-path windows/Cargo.toml -p lightray-windows gpu_lifecycle -- --ignored
cargo test --manifest-path windows/Cargo.toml -p lightray-windows apple_videotoolbox -- --ignored
```

`--no-decode` explicitly limits a run to encode and transport. The JSON output distinguishes actual frame counts, transport repair, process memory/CPU, and CPU durations of capture/conversion, encode, decode, and conversion/present calls. An unattached composition swap chain verifies GPU submission, not physical displayed FPS, scanout, or input-to-photon latency. Desktop capture, UI input, real LAN behavior, and Mac interoperability require their separate acceptance checks.

For a synthetic host with no input injection or login changes:

```powershell
$env:LIGHTRAY_DATA_DIR = Join-Path $PWD 'windows/target/isolated-host'
windows/target/release/lightray-host-agent.exe pair --output windows/target/test-pairing.txt
windows/target/release/lightray-host-agent.exe --synthetic --log-input --port 7374 --seconds 60
```

In a second terminal, run the published Windows client or the existing Mac client against port 7374 with that pairing file. The client also accepts `--connect ADDRESS --pair-file FILE` for isolated runs. Treat the exported file as a secret; it is for this test identity only.

Before accepting cross-platform compatibility, use the MacBook to test **Mac client → Windows host** and **Windows client → Mac host** with the matching current Apple build. Check first video, text/keyboard/buttons/wheel, display selection, independent stream recovery, temporary network loss, resize/hotplug, lock/unlock, and reconnect. Windows loopback and checked-in Apple bitstreams do not replace that network test.

Checked-in local evidence is under [`validation/`](validation/README.md), including the ten-minute encrypted UDP run and an attached WinUI streaming window. The native platform's codec/lifecycle evidence is in `platform/validation-results.json`.

Audio, microphone, gamepads, relative mouse, HDR, Intel/AMD encoding, discovery, NAT traversal, explicit PARK/RESUME, session takeover, adaptive rate control, and long-term reference recovery are deferred. The historical C++/Swift laboratory in `tools/windows` remains unchanged as research material.
