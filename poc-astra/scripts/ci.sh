#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build
swift test
swift test -c release
swift run -c release lightray-demo benchmark --seconds 2 --mbps 20
if [ "${LIGHTRAY_BENCHMARKS:-0}" = 1 ]; then
    cd Benchmarks
    BENCHMARK_DISABLE_JEMALLOC=true swift package benchmark --no-progress
fi
