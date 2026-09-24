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

mkdir -p build
xcrun devicectl list devices --json-output build/devices.json >/dev/null 2>&1
# First physical (not simulated) iPad: "<udid> <product type>".
read -r device model <<EOF
$(python3 -c "
import json
for d in json.load(open('build/devices.json'))['result']['devices']:
    hw = d.get('hardwareProperties', {})
    if hw.get('deviceType') == 'iPad' and hw.get('reality') != 'simulated':
        print(hw['udid'], hw.get('productType', 'iPad').replace(',', '-')); break
")
EOF
[ -n "${device:-}" ] || { echo "no physical iPad found (xcrun devicectl list devices)" >&2; exit 1; }

app=$(./build.sh device "$team" "$device" | tail -1)
xcrun devicectl device install app --device "$device" "$app"

swiftc -O -parse-as-library host/ProbeHost.swift -o build/probehost
out="../../results/ipad-${model:-device}-$(date +%Y%m%d-%H%M).txt"
echo "ProbeHost writing $out; launching the probe with -host $mac_ip $*"
xcrun devicectl device process launch --device "$device" --terminate-existing dev.lightray.probe -host "$mac_ip" "$@"
exec ./build/probehost -o "$out"
