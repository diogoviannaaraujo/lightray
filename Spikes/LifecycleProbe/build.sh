#!/bin/sh
# Builds LifecycleProbe.app for the iOS Simulator without an Xcode project.
set -eu
cd "$(dirname "$0")"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
APP=build/LifecycleProbe.app
rm -rf build && mkdir -p "$APP"
xcrun --sdk iphonesimulator swiftc -O -parse-as-library -swift-version 5 \
    -target arm64-apple-ios26.0-simulator -sdk "$SDK" \
    LifecycleProbe.swift -o "$APP/LifecycleProbe"
cat > "$APP/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.lightray.lifecycleprobe</string>
    <key>CFBundleExecutable</key><string>LifecycleProbe</string>
    <key>CFBundleName</key><string>LR Probe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
    <key>MinimumOSVersion</key><string>26.0</string>
    <key>LSRequiresIPhoneOS</key><true/>
    <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
    <key>UILaunchScreen</key><dict/>
    <key>UIApplicationSceneManifest</key>
    <dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
</dict>
</plist>
EOF
codesign --force --sign - "$APP" >/dev/null
echo "$APP"
