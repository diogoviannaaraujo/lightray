# Lightray for iPad

The iPad client proof of concept targets iPadOS 27 and uses the shared
[`LightrayCore`](../apple/README.md) package for the Lightray protocol, transport, and video.
The app uses Swift 6 language mode and complete concurrency checking.

## Build

Requires Xcode 27 with the iOS 27 SDK. Keep `ios/` beside `apple/` in the checkout; the Xcode
project references that package locally and needs no third-party dependencies.

Open `ios/Lightray.xcodeproj`, select the **Lightray** scheme, and choose an iPad simulator
or a connected iPad running iPadOS 27 or later. For a physical device, choose your development
team under **Signing & Capabilities** and enable Developer Mode on the iPad.

Build for the simulator from the repository root:

```bash
xcodebuild -project ios/Lightray.xcodeproj -scheme Lightray \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ios/.build/simulator build
```

Build for a device with your team, allowing Xcode to create the development provisioning profile:

```bash
xcodebuild -project ios/Lightray.xcodeproj -scheme Lightray \
  -destination 'generic/platform=iOS' -derivedDataPath ios/.build/device \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=YOUR_TEAM_ID build
```

The project leaves the signing team unset so it can be built with another developer's account.
Its development bundle identifier is `io.lightray.ipad`; override `PRODUCT_BUNDLE_IDENTIFIER`
if your team's provisioning setup requires a different identifier.

The app supports portrait, landscape, and resizable iPad windows. It keeps one app window and
one remote session at a time. Allow **Local Network** access when connecting to a computer.

## Connect

Build and start the Mac host as described in [`macos/`](../macos/README.md):

```bash
swift build -c release --package-path macos
macos/.build/release/lightray-host pair
macos/.build/release/lightray-host
```

On iPad, tap **Add computer**, enter the Mac's LAN hostname or address, and paste the pairing
token. **Import pairing file** accepts a text file containing that token. The default UDP port is
7373; enter `hostname:port` or `[IPv6]:port` to use another. Keep the token private: it authorizes
control of the host. Remembered credentials stay in this device's Keychain; names and addresses
are saved separately. Uncheck **Remember this computer** for a temporary connection.

The host needs Screen Recording and Accessibility permissions for a real desktop. For a safe
first run without those permissions:

```bash
macos/.build/release/lightray-host --test-pattern 1280x720 --log-input
```

Use the Mac's network address from a physical iPad. A simulator on the Mac can use `127.0.0.1`.

## Controls and lifecycle

- Tap to click; drag with one finger to hold the primary mouse button and move. The drag starts
  at the initial touch location after UIKit recognizes the gesture. Letterbox areas ignore input.
- Tap with two fingers for a secondary click; drag with two fingers to scroll. Pencil also works
  as a pointer; pressure and tilt are not sent.
- A mouse or trackpad supports hover, buttons and scrolling. A hardware keyboard sends physical
  HID keys. iPadOS keeps its reserved system shortcuts. There is no software keyboard yet.
- **Displays** switches the single video stream between the host's available displays.
- **Session** offers statistics, input enable/disable, Escape, Tab, release-all-keys and reconnect.
  **Disconnect** returns to Computers. Swipe a remembered computer to forget its pairing.
- Losing focus releases held keys and buttons. Entering the background closes the session.
  Foreground entry creates a fresh socket, decoder and renderer and restores the selected display
  if it still exists. Opening Control Center releases input without closing the session.

The interface uses SwiftUI and Observation, with a UIKit input surface. VideoToolbox decoding and
the iOS 27 `AVSampleBufferVideoRenderer.Receiver` presentation path come from `LightrayCore`.
Network setup happens away from the main actor; attempts time out after 12 seconds. An active
connection prevents auto-lock; disconnecting or backgrounding restores it.

## Validation

Run the app-hosted tests on an iPadOS 27 simulator:

```bash
xcrun simctl list devices available
xcodebuild -project ios/Lightray.xcodeproj -scheme Lightray \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -derivedDataPath ios/.build/simulator test
```

Simulator builds must retain their default ad-hoc signing to use the Keychain. Do not set
`CODE_SIGNING_ALLOWED=NO` when running the app or its tests; that option is only useful for a
compile check. No development team is needed for the simulator.

For an end-to-end test, build the Mac host, create its pairing once, and boot an iPadOS 27
simulator. Then, from the repository root:

```bash
python3 ios/scripts/smoke-test.py --simulator SIMULATOR_UDID
```

The script builds the app and tests, starts a synthetic host on UDP 17373 (`--port` overrides it),
and checks Keychain storage, validation, cancellation during setup, timeout across retries, live
video, display switching, input delivery, foreground reconnection and explicit reconnect. It
passes the host token through a private temporary app-container file, removes it afterward, and
stops its own host. Logs and a live-stream screenshot go in the ignored `ios/.build/` directory.
The network integration test skips in ordinary test runs without that temporary configuration.

## POC limits

One session and one display at a time. Audio, clipboard, game controllers, discovery, software
keyboard, picture-in-picture, and protocol-level park/resume are not implemented. Returning from
the background authenticates a new session; it does not claim protocol session continuity.
The shared core's provisional input and display-selection formats match the current Mac host.
Physical-device latency and touch/trackpad ergonomics still need validation on an available iPad.
