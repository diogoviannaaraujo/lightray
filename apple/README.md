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

The [release workflow](../.github/workflows/release.yml) runs on every push to `main`,
version tags, and manual dispatches. Pull requests run the same validation without signing or
uploading: shared core and host tests, a Mac client build, iPad simulator tests, protocol vectors,
and matching Apple/Windows versions.
Simulator CI explicitly excludes the two integration tests that require a manually configured
host and limits each remaining test to three minutes. Run the opt-in host tests through the
[iPad validation scripts](ios-client/README.md#validation).

Distributions share a FIFO concurrency queue across main pushes, tags, and manual runs, with up to
100 pending runs. New pushes keep earlier pending runs instead of replacing them. This also
avoids concurrent uploads racing Apple's monotonically increasing build numbers. To upload an
old commit after newer builds, dispatch a new run rather than rerunning an old numbered run.

After validation, three independent jobs produce both signed and notarized Mac DMGs plus the CLI
archive, upload the iOS client to TestFlight, and upload the native sandboxed macOS client to
TestFlight. Every distributed Apple build uses `RUN_NUMBER.RUN_ATTEMPT` as its build number,
including the Mac host service. The version remains `MAJOR.MINOR.PATCH` from the source plists.
TestFlight jobs wait for Apple processing and fail if the build is invalid, missing compliance,
or not available to internal testers within 30 minutes. See the job logs for the App Store
Connect link. An internal tester group must have automatic distribution enabled.

Download DMGs and `SHA256SUMS.txt` from **Actions → Release → the main commit → Artifacts →
lightray-macos-arm64**. iOS IPAs and macOS App Store packages are also retained as separate
artifacts, including when upload/processing fails. Artifacts last 14 days.

All Mac app/service plists must have matching source versions and build numbers, the iOS marketing
version must match, and `windows/Cargo.toml` must use the same version. Push a matching
`vMAJOR.MINOR.PATCH` tag to create a draft GitHub release with Mac and Windows downloads after all
Apple distributions succeed. Existing releases are never overwritten. Windows retains its
path-filtered push/PR workflow; tag and manual releases call it explicitly with the release version.
Ordinary Windows runs resolve their package version from Cargo instead of a hardcoded default.
Manual runs can disable both TestFlight uploads with the **testflight** checkbox.

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
key. Main pushes and tagged releases fail without these secrets; manual runs fall back to ad-hoc signatures with a
warning. The first signed release changes the apps' code identity, so macOS asks for Lightray
Host's screen and input permissions and background approval once more.

### TestFlight

Every main push and version tag uploads both clients. Manual runs upload both by default.
The iOS job archives and exports the iPad app with an Apple Distribution certificate and iOS
App Store profile. The macOS job packages the native Swift client using the same Apple Distribution
certificate, a Mac App Store profile, and a Mac Installer Distribution certificate.
The existing `IOS_DISTRIBUTION_*` secret names are retained because Apple Distribution works on
both platforms. These secrets are required in addition to the API key above:

| Secret | Contents |
|---|---|
| `IOS_DISTRIBUTION_P12` | Apple Distribution certificate and private key, exported as `.p12`, base64-encoded; used for both clients |
| `IOS_DISTRIBUTION_PASSWORD` | The `.p12` export password |
| `IOS_APP_STORE_PROFILE` | iOS App Store Connect profile for `com.getlightray.client`, base64-encoded |
| `MACOS_APP_STORE_PROFILE` | Mac App Store Connect profile for `com.getlightray.client`, base64-encoded |
| `MACOS_INSTALLER_P12` | Mac Installer Distribution certificate and private key, exported as `.p12`, base64-encoded |
| `MACOS_INSTALLER_PASSWORD` | The installer `.p12` export password |

Register `com.getlightray.client` under Identifiers and create the App Store Connect app record
with iOS and macOS platforms before the first uploads. Create each profile for its platform and
the same Apple Distribution certificate. Create the Mac Installer Distribution certificate in
Certificates, Identifiers & Profiles (its signing name is `3rd Party Mac Developer Installer`).
Renew expiring certificates/profiles together and update the corresponding repository secrets.

The macOS TestFlight client enables App Sandbox, outbound/inbound network access for UDP, and
read access to pairing files chosen through the open panel. Its settings and pairing live inside
the sandbox, separately from the Developer ID DMG app. The host remains a separate Developer ID
DMG with its independent sharing service.

Both clients declare `ITSAppUsesNonExemptEncryption = NO`: cryptographic algorithms are supplied
by Apple's CryptoKit framework. Revisit the declaration if the encryption implementation changes.
Apple's [encryption export guidance](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)
explains the declaration. The first iOS build was uploaded as `0.1.0 (4.1)`; its missing-compliance
prompt was completed in App Store Connect during this CI setup.

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
