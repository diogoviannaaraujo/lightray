# Apple app separation validation — 2026-10-15

Implementation and automated validation are complete. Full installed-service acceptance remains
pending the interactive checks below; this report does not establish sharing across logout/login.

Environment: Apple Silicon, macOS 27.0.1 (26A434), Xcode 27.0, Swift 6.4.
Final Mac app and helper version: 0.1.0, build 5.

## Automated checks

| Check | Result |
|---|---|
| Core tests | 128 passed |
| Host tests | 11 XCTest and 10 Swift Testing tests passed |
| Both Mac release packages | Built successfully |
| iPad simulator app | Built successfully with the existing Lightray scheme |
| Protocol vectors and specification links | 16 blocks checked, no problems |
| iPad smoke test | Passed pairing, timeout/cancellation, video, display switching, input delivery, and reconnect against the relocated synthetic host |
| Core compatibility | Production changes are documentation paths only; public API and wire behavior unchanged |
| Bundle separation | Client contains no host executable; Host contains the accessory helper and LaunchAgent plist |
| Package validation | Both DMGs mounted read-only; bundle signatures verified; matching app/helper versions and executable CLI archive permissions checked |
| Checksums | Both DMGs and combined CLI archive passed SHA-256 verification |

Host lifecycle tests cover initial disabled state, migration without enabling, persistent stop,
approval handling, unavailable XPC, registration/unregistration failures, invalid or unwritable
settings, startup failure from an occupied port, and runtime shutdown that releases its socket
without exiting the process.

## Graphical-session checks performed

- Opening Host did not enable sharing. Start Sharing registered the per-user SMAppService agent.
- An early development build obtained capture and Accessibility permission in the service process.
  A local Mac client connected using the existing host pairing file, decoded the real desktop,
  and saved a frame. The first decoded frame arrived in approximately 390 ms; streaming ran at
  approximately 29 fps with the Balanced profile. This was a loopback test on one Mac.
- Quitting Host settings left that service running. A deliberate service crash was restarted by
  launchd, and capture resumed.
- Stop Sharing removed the launchd registration. Reopening Host kept sharing off, including with
  the final installed build. Final settings have `enabled: false`.
- Revoking Lightray Host's background approval in System Settings produced the approval-required
  state. The app did not restore approval automatically.
- Installed upgrades signed with the same Apple Development identity succeeded: build 3 → 4 and
  build 4 → 5 refreshed registration, launched the new helper, and reported its runtime status
  through XPC. These upgrade checks exercised the idle missing-permission state.
- An unrelated executable was rejected when requesting XPC status from the running signed service.

The initial ad-hoc rebuild failed to launch with a macOS code-signing constraint error. Changing
to a development identity required explicitly reapproving Lightray Host's background activity.
Subsequent upgrades with that stable identity succeeded. Ad-hoc packaging is retained for local
development; use a stable Apple-issued identity for installed upgrade and login acceptance.

After the signing change, capture permission still required an authenticated System Settings
action. The Touch ID prompt was not completed during testing. The final service correctly stayed
idle and reported the missing permission without repeatedly prompting or restarting.

## Remaining acceptance

1. Complete Screen Recording and Accessibility approval for the installed signed helper, then
   verify actual capture and input injection from a second Mac or physical iPad.
2. With sharing enabled, log out and back in. Confirm sharing resumes without opening a settings
   window or creating a Dock icon, and reconnect from the other device.
3. Stop Sharing, log out/in again, and confirm the service remains unregistered and sharing stays off.
4. Exercise permission revocation and an occupied port with the installed signed service. The
   automated tests cover these failure states, but do not replace the installed checks.

The final Host app is installed in `/Applications/Lightray Host.app` and left stopped.
Local build artifacts are under `apple/.build/apps/`; diagnostic logs are under
`apple/.build/validation/` and the iPad smoke logs under `apple/ios-client/.build/`.
The DMGs use a local development signature and are not notarized. No release was published.
