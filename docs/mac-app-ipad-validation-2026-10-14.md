# Mac app and physical iPad validation — October 14, 2026

Tested the native `Lightray.app` installed in `/Applications` against `vogoidpad`, an iPad mini
(A17 Pro) running iPadOS 27. The iPad used its existing `vogoidbook:7373` pairing over Tailscale.
The host used Balanced quality: 1710 × 1112, capped at 30 fps. Screen Recording and Accessibility
were granted to the new Mac app with the user's approval. The installed app's strict code-signature
validation passed, and its executables match the packaged build.

## Issue found and fixed

An established session previously stopped reconnecting after 12 seconds without authentication,
returned to Computers, and required another tap to connect. This was reproduced by stopping the
Mac app's host while the physical iPad was streaming.

`ClientSession` now distinguishes an initial connection from recovery of an authenticated session.
Initial attempts still time out after 12 seconds. Recovery keeps retrying while the app is in the
foreground, recreates the socket and resolves the host again after longer outages, and retries
transient setup failures. Disconnect cancels recovery; backgrounding closes the transport, with
recovery continuing on foreground entry.

## Manual checks

| Scenario | Observed result |
| --- | --- |
| Open the installed Mac app and start sharing | Sharing became ready; embedded host owned UDP 7373. |
| Saved iPad pairing after a cold launch/update | Pairing remained available and connected without re-pairing. |
| Replace standalone host with bundled host | iPad automatically connected to the bundled host and displayed the desktop. |
| Stop sharing, leave host unavailable, restart | Fixed build recovered automatically after a measured 47.7-second disconnect-to-authentication interval. No iPad interaction was needed. |
| Time from restarted host to picture | Host authenticated the iPad 2.351 seconds after startup; first decoded frame followed 96 ms later, about 2.45 seconds total. |
| Unannounced eight-second host silence | Paused/resumed the host process to simulate silence. iPad detected five seconds without traffic, authenticated a new session on resumption, and decoded its first frame 39 ms after authentication. This was not a physical Wi-Fi network change. |
| Background/foreground | Device Hub Home action closed the old session. Bringing the same process to the foreground with `devicectl` resumed streaming; first decoded frame arrived 170 ms after authentication. Keyboard was hidden on return. |
| Keyboard toolbar button | Native iPad keyboard appeared; remote desktop resized above it. Toolbar button hid it again. |
| Onscreen typing and Backspace | Actual taps on software keys wrote `lightray` into a dedicated Mac test field. Eight Backspaces cleared a prior eight-character trial correctly; no duplicate characters were observed. |
| Remote pointer | Tap on the test button incremented the Mac fixture's click count. |
| Close Mac windows | Bundled host remained running; the iPad connected while the windows had been closed. Sharing controls reopened from the app menu. |
| Stream after recovery | Observed 29–30 decoded fps, approximately 11–24 ms RTT, and approximately 3 ms decode time in stable samples. |

The longer diagnostic log includes packet loss and decoder queue drops, particularly around
transitions. These checks do not establish a zero-drop or uninterrupted five-hour performance
guarantee. The 60 fps and native-resolution profiles were not revalidated in this run.

Device Hub later stopped forwarding some coordinate taps, including taps on the iPad Home Screen.
Background recovery was therefore completed with `devicectl` foreground activation, without
terminating the app. Final manual Disconnect/Session-Reconnect button checks were inconclusive
through that viewer; their model behavior is covered by the automated integration tests below.
A directly attached hardware keyboard, physical multi-touch gestures, Wi-Fi network switching,
and Mac sleep/wake remain outside this run's verified scope.

## Automated regression checks

- Physical iPad: 6 passed, 2 opt-in integration tests skipped, 0 failures.
- Simulator with synthetic Mac host: 7 passed, 1 opt-in desktop test skipped, 0 failures.
- New regression uses a real local UDP/authentication peer: established connection, more than
  12 seconds offline, automatic recovery, foreground recovery during an outage, and explicit
  disconnect. Initial unreachable-host timeout remains covered separately.
- Synthetic-host integration confirms live video, display switching, Unicode text and editing
  key delivery to the host, input release, foreground recovery, and explicit reconnect.
- Earlier checks for the same keyboard/Mac-app changes: 128 shared-core tests, 6 host tests,
  and 3 desktop helper lifecycle tests passed.

## Evidence and deliverables

Local logs are in the ignored `ios/.build/manual-2026-10-14/` directory:
`device-tests.log`, `ipad-console.log`, `connection-events.log`, `host-silence.log`,
`host-before-restart.log`, `host-before-fixed-recovery.log`,
`host-before-afternoon-restart.log`, and `simulator-smoke.log`.
Simulator details are in `ios/.build/smoke-tests.log` and `ios/.build/smoke-host.log`.
These logs intentionally omit pairing tokens.

The app is installed at `/Applications/Lightray.app`; the installer is
`macos/.build/app/Lightray-0.1.0-arm64.dmg`. This is a development-signed local build;
Developer ID signing and notarization remain necessary for public distribution.
