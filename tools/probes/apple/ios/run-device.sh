#!/bin/sh
# Builds, installs and launches the probe on a connected iPad, with ProbeHost listening on this Mac.
#   ./run-device.sh <TEAM_ID> [mac-ip] [extra launch arguments...]
# Example: ./run-device.sh ABCDE12345 192.168.1.109 -auto
# Results are written to tools/probes/results/ipad-<model>-<date>.txt by ProbeHost.
set -eu
cd "$(dirname "$0")"
team=${1:?usage: ./run-device.sh <TEAM_ID> [mac-ip] [args...]}
shift
mac_ip=${1:-$(ipconfig getifaddr en0 || ipconfig getifaddr en1)}
[ $# -gt 0 ] && shift

device=$(xcrun devicectl list devices 2>/dev/null | awk '/iPad/ && !/unavailable/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F-]{36}$/) { print $i; exit } }')
[ -n "$device" ] || { echo "no connected iPad found (xcrun devicectl list devices)" >&2; exit 1; }

app=$(./build.sh device "$team" | tail -1)
xcrun devicectl device install app --device "$device" "$app"

mkdir -p build
swiftc -O -parse-as-library host/ProbeHost.swift -o build/probehost
model=$(xcrun devicectl list devices 2>/dev/null | awk -v d="$device" '$0 ~ d { print $NF }' | tr -d '()' | tr ',' '-')
out="../../results/ipad-${model:-device}-$(date +%Y%m%d-%H%M).txt"
echo "ProbeHost writing $out; launching the probe with -host $mac_ip $*"
xcrun devicectl device process launch --device "$device" --terminate-existing dev.lightray.probe -host "$mac_ip" "$@"
exec ./build/probehost -o "$out"
