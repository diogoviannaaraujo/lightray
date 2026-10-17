# Apple applications

| Project | Responsibility |
|---|---|
| [core](core/README.md) | Shared Swift protocol, transport, pairing, and media |
| [mac-client](mac-client/README.md) | Lightray: connects to host devices |
| [mac-host](mac-host/README.md) | Lightray Host: settings and independent login sharing service |
| [ios-client](ios-client/README.md) | Existing iPad client, using the same core |

The Mac apps are independent Swift packages and installable apps. The iPad app remains an Xcode
project. Each depends on `core` by a sibling path. Keep the entire repository checkout so the core
tests can read the protocol vectors and all apps can compile the shared icon source.

## Build and test

Requires macOS 27, Xcode 27, and Swift 6.4. Run from the repository root:

```bash
swift test --package-path apple/core
swift test --package-path apple/mac-host
swift build -c release --package-path apple/mac-client
swift build -c release --package-path apple/mac-host
swift run --package-path tools/vectors lightray-vectors check
xcodebuild -project apple/ios-client/Lightray.xcodeproj -scheme Lightray \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath apple/ios-client/.build/simulator build
```

## Packaging and releases

```bash
python3 apple/scripts/package-app.py --app all
```

Use `--app client` or `--app host` to package one role. Outputs default to `apple/.build/apps`:
`Lightray.app`, `Lightray Host.app`, `Lightray-VERSION-arm64.dmg`, and
`LightrayHost-VERSION-arm64.dmg`. Each disk image contains one independent app.
`--output`, `--skip-build`, and `--no-dmg` are also supported.

The script compiles the shared Icon Composer source, signs the nested host service before its
containing app, and verifies both bundles. It defaults to local ad-hoc signatures; pass
`--sign "SIGNING_IDENTITY"` for an installed signing certificate. Public distribution also
requires notarization, which the release workflow performs (see [Release signing](#release-signing)).

Use the same Apple-issued signing identity for installed-service lifecycle and upgrade tests.
Ad-hoc builds remain available for local development, but rebuilding changes their identity and
can invalidate macOS background-service and privacy approvals. When changing signing identities,
stop sharing and explicitly review Lightray Host's approval in System Settings before retesting.

The [release workflow](../.github/workflows/release.yml) tests core and host, builds the
client and iPad simulator app, checks protocol examples, then packages both DMGs. It also produces
`Lightray-VERSION-macos-arm64-cli.tar.gz` with both CLI executables. The same workflow builds
the [Windows applications](../windows/README.md), and the draft release carries both platforms'
files with one `SHA256SUMS.txt`.
All Mac app/service plists must have matching versions and build numbers, and the workspace version
in `windows/Cargo.toml` must match them. Update them together, commit, and push a matching `vMAJOR.MINOR.PATCH` tag to create a draft release. Existing releases
are never overwritten. Manual workflow runs upload artifacts without creating a release.
Artifacts are retained for 14 days; published release assets persist independently.

### Release signing

The workflow signs both apps, their disk images, and the CLI executables with a Developer ID
Application certificate, notarizes the disk images and a zip of the CLI executables, and staples
the disk images. It reads these repository secrets:

| Secret | Contents |
|---|---|
| `MACOS_DEVELOPER_ID_P12` | The Developer ID Application certificate and private key, exported as `.p12`, base64-encoded |
| `MACOS_DEVELOPER_ID_PASSWORD` | The `.p12` export password |
| `APPLE_NOTARY_KEY` | The App Store Connect API key file (`AuthKey_KEYID.p8`), as text; it also uploads TestFlight builds |
| `APPLE_NOTARY_KEY_ID` | That key's ID |
| `APPLE_NOTARY_ISSUER_ID` | The issuer ID shown above the team keys in App Store Connect |

The Account Holder creates the certificate in Xcode (Settings → Accounts → the team → Manage
Certificates → + → Developer ID Application) and exports it from Keychain Access with its private
key. Tagged releases fail without these secrets; manual runs fall back to ad-hoc signatures with a
warning. The first signed release changes the apps' code identity, so macOS asks for Lightray
Host's screen and input permissions and background approval once more.

### TestFlight

Tagged releases also upload the iPad app to TestFlight; a manual run does so when its
**Upload the iPad app to TestFlight** box is ticked. The job signs only the app target with an
Apple Distribution certificate and an App Store provisioning profile, sets the build number to
`RUN_NUMBER.RUN_ATTEMPT`, and uploads with the API key above, which needs at least Developer
access. The iPad `MARKETING_VERSION` must match the Mac apps' version. Besides the API key secrets,
the job reads:

| Secret | Contents |
|---|---|
| `IOS_DISTRIBUTION_P12` | The Apple Distribution certificate and private key, exported as `.p12`, base64-encoded |
| `IOS_DISTRIBUTION_PASSWORD` | The `.p12` export password |
| `IOS_APP_STORE_PROFILE` | An App Store Connect provisioning profile for `com.getlightray.client`, base64-encoded |

The bundle ID must be registered under Identifiers, and an App Store Connect app record must use it,
before the first upload. Both the certificate and the profile expire after a year; renew them
together and replace the three secrets.

## Installed-service acceptance

See the [validation report](../docs/apple-split-validation-2026-10-15.md) for completed checks and
the remaining interactive acceptance steps.

Unit tests use injected registration and XPC dependencies; they do not change login items.
Validate the signed, installed host separately in a graphical macOS session:

1. Open Host and confirm sharing is off until Start Sharing. Finish background and privacy approval.
2. Connect a Mac or iPad and verify video and input. Close and quit both settings/client apps;
   reconnect from the other device and verify the menu bar service remains available.
3. Restart the service process unexpectedly and confirm launchd recovery. Log out and back in,
   then verify sharing resumes without a window or Dock icon.
4. Stop Sharing, restart apps, and log out/in again. Confirm the service stays unregistered.
5. Exercise missing/revoked permissions, background approval revocation, an occupied port, and
   an upgraded signed app. Confirm truthful status and explicit recovery without losing pairing.

Logout/login and actual privacy grants require a graphical user session; successful unit tests
and packaging alone do not establish this acceptance. The [iPad smoke test](ios-client/README.md#validation)
checks streaming and input using a synthetic host without screen-capture permissions.
