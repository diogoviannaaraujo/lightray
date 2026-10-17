# Lightray for iPad

The iPad client proof of concept targets iPadOS 27 and uses the shared
[`LightrayCore`](../core/README.md) package for the Lightray protocol, transport, and video.
The app uses Swift 6 language mode and complete concurrency checking.

## Build

Requires Xcode 27 with the iOS 27 SDK. Keep `apple/ios-client/` beside `apple/core/` in the checkout; the Xcode
project references that package locally and needs no third-party dependencies.
The app icon uses the shared [`assets/lightray.icon`](../../assets/README.md) Icon Composer source.

Open `apple/ios-client/Lightray.xcodeproj`, select the **Lightray** scheme, and choose an iPad simulator
or a connected iPad running iPadOS 27 or later. For a physical device, choose your development
team under **Signing & Capabilities** and enable Developer Mode on the iPad.

Build for the simulator from the repository root:

```bash
xcodebuild -project apple/ios-client/Lightray.xcodeproj -scheme Lightray \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath apple/ios-client/.build/simulator build
```

Build for a device with your team, allowing Xcode to create the development provisioning profile:

```bash
xcodebuild -project apple/ios-client/Lightray.xcodeproj -scheme Lightray \
  -destination 'generic/platform=iOS' -derivedDataPath apple/ios-client/.build/device \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=YOUR_TEAM_ID build
```

The project leaves the signing team unset so it can be built with another developer's account.
Its bundle identifier is `com.getlightray.client`, shared with the Mac client; override
`PRODUCT_BUNDLE_IDENTIFIER` if your team's provisioning setup requires a different identifier.

The app supports portrait, landscape, and resizable iPad windows. It keeps one app window and
one remote session at a time. Allow **Local Network** access when connecting to a computer.

## Connect

Build and start the Mac host as described in [`apple/mac-host/`](../mac-host/README.md):

```bash
swift build -c release --package-path apple/mac-host
apple/mac-host/.build/release/lightray-host pair
apple/mac-host/.build/release/lightray-host
```

On iPad, tap **Add computer**, enter the Mac's LAN hostname or address, and paste the pairing
token. **Import pairing file** accepts a text file containing that token. The default UDP port is
7373; enter `hostname:port` or `[IPv6]:port` to use another. Keep the token private: it authorizes
control of the host. Remembered credentials stay in this device's Keychain; names and addresses
are saved separately. Uncheck **Remember this computer** for a temporary connection.

The host needs Screen Recording and Accessibility permissions for a real desktop. For a safe
first run without those permissions:

```bash
apple/mac-host/.build/release/lightray-host --test-pattern 1280x720 --log-input
```

Use the Mac's network address from a physical iPad. A simulator on the Mac can use `127.0.0.1`.

## Controls and lifecycle

- The remote display fills the screen, without the navigation bar, status bar or Home indicator.
  The session tools live in a floating Liquid Glass button: tap it to show the list. Drag it to
  another corner if it covers something; the corner is remembered. Swipes from the top or bottom
  edge need a second swipe, so touchpad drags near an edge stay on the host.
- Fingers work as a touchpad anywhere on the screen. Drag with one finger to move the pointer;
  faster movements go farther. Tap to click, tap with two fingers for a secondary click, and drag
  with two fingers to scroll. To drag with the button held, double-tap and drag: a tap holds the
  button for 250 ms, and a touch landing in that time keeps it held until you lift.
- Pinch to zoom, up to 5×. A zoomed picture stays centred on the cursor and follows it, short of
  the display's edges. **Show whole display** zooms back out. The client can't see the host's own
  mouse, so after connecting or switching displays the pointer starts from the middle.
- Pencil points directly: tap to click where it touches, drag to hold the primary button.
  Letterbox areas ignore it. Pressure and tilt are not sent.
- A mouse or trackpad supports hover, buttons and scrolling, and points directly. When zoomed,
  the picture pans with the pointer so the cursor stays under it, and a trackpad pinch zooms.
  A hardware keyboard sends physical HID keys. iPadOS keeps its reserved system shortcuts.
- The **keyboard** button shows or hides the onscreen keyboard. Tap a text field on the remote
  desktop, then type; Return and Backspace work on the host. The keyboard closes when input is
  disabled or the session leaves the foreground. Text entry requires an updated Mac host with
  the provisional `TEXT` input message; older hosts ignore it.
- **Displays** switches the single video stream between the host's available displays.
- **Session** offers statistics, input enable/disable, Escape, Tab, release-all-keys and reconnect.
  **Disconnect** (the power button) returns to Computers. Swipe a remembered computer to forget
  its pairing.
- Losing focus releases held keys and buttons. Entering the background closes the session.
  Foreground entry creates a fresh socket, decoder and renderer and restores the selected display
  if it still exists. Opening Control Center releases input without closing the session.

The interface uses SwiftUI and Observation, with a UIKit input surface. VideoToolbox decoding and
the iOS 27 `AVSampleBufferVideoRenderer.Receiver` presentation path come from `LightrayCore`.
Network setup happens away from the main actor; initial connections time out after 12 seconds.
Once authenticated, an interrupted session keeps reconnecting while the app is in the foreground,
refreshing its socket and host address after longer outages. Disconnect cancels recovery.
An active connection prevents auto-lock; disconnecting or backgrounding restores it.

## Validation

Run the app-hosted tests on an iPadOS 27 simulator:

```bash
xcrun simctl list devices available
xcodebuild -project apple/ios-client/Lightray.xcodeproj -scheme Lightray \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -derivedDataPath apple/ios-client/.build/simulator test
```

Simulator builds must retain their default ad-hoc signing to use the Keychain. Do not set
`CODE_SIGNING_ALLOWED=NO` when running the app or its tests; that option is only useful for a
compile check. No development team is needed for the simulator.

For an end-to-end test, build the Mac host, create its pairing once, and boot an iPadOS 27
simulator. Then, from the repository root:

```bash
python3 apple/ios-client/scripts/smoke-test.py --simulator SIMULATOR_UDID
```

The script builds the app and tests, starts a synthetic host on UDP 17373 (`--port` overrides it),
and checks Keychain storage, validation, cancellation during setup, timeout across retries, live
video, display switching, input delivery, foreground reconnection and explicit reconnect. It
passes the host token through a private temporary app-container file, removes it afterward, and
stops its own host. Logs and a live-stream screenshot go in the ignored `apple/ios-client/.build/` directory.
The network integration test skips in ordinary test runs without that temporary configuration.

## POC limits

One session and one display at a time. Audio, clipboard, game controllers, discovery,
picture-in-picture, and protocol-level park/resume are not implemented. Returning from
the background authenticates a new session; it does not claim protocol session continuity.
The shared core's provisional input and display-selection formats match the current Mac host.
Physical-device latency, touchpad acceleration and the mouse magnifier still need validation on
an available iPad.
