#!/bin/sh
# Builds the iPad probe.
#   ./build.sh sim               for the iOS Simulator, unsigned
#   ./build.sh device <TEAM_ID> [UDID]  for a real iPad, signed with your development team
# Prints the path of the built LightrayProbe.app.
set -eu
cd "$(dirname "$0")"
mode=${1:-sim}

# HEVC clips the decoder probe checks for hardware support: Main10, 4:4:4 and 4:2:2.
mkdir -p Samples
if command -v ffmpeg >/dev/null 2>&1; then
    clip() {
        name=$1
        shift
        [ -f "Samples/$name.hevc" ] && return 0
        ffmpeg -loglevel error -f lavfi -i testsrc2=size=1920x1080:rate=60 -frames:v 60 \
            -c:v libx265 -x265-params "bframes=0:keyint=600:log-level=error" "$@" -f hevc "Samples/$name.hevc"
    }
    clip main10-420 -pix_fmt yuv420p10le -profile:v main10
    clip main444-8 -pix_fmt yuv444p -profile:v main444-8
    clip main444-10 -pix_fmt yuv444p10le -profile:v main444-10
    clip main422-10 -pix_fmt yuv422p10le -profile:v main422-10
else
    echo "ffmpeg not found: the format-support clips are skipped" >&2
fi

xcodegen generate --spec project.yml --quiet
case $mode in
    sim)
        xcodebuild -project LightrayProbe.xcodeproj -scheme LightrayProbe -configuration Release \
            -destination 'generic/platform=iOS Simulator' -derivedDataPath build/dd -quiet build
        find build/dd/Build/Products/Release-iphonesimulator -maxdepth 1 -name LightrayProbe.app
        ;;
    device)
        team=${2:?usage: ./build.sh device <TEAM_ID> [DEVICE_UDID]}
        # Naming the device lets Xcode register it in the team's provisioning profile.
        destination='generic/platform=iOS'
        [ -n "${3:-}" ] && destination="platform=iOS,id=$3"
        xcodebuild -project LightrayProbe.xcodeproj -scheme LightrayProbe -configuration Release \
            -destination "$destination" -derivedDataPath build/dd \
            -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
            DEVELOPMENT_TEAM="$team" -quiet build
        find build/dd/Build/Products/Release-iphoneos -maxdepth 1 -name LightrayProbe.app
        ;;
    *)
        echo "usage: ./build.sh sim | device <TEAM_ID>" >&2
        exit 2
        ;;
esac
