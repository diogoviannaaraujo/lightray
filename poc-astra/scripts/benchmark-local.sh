#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release
benchmark_binary="$(swift build -c release --show-bin-path)/lightray-demo"
benchmark_output="${1:-Docs/benchmarks}"
mkdir -p "$benchmark_output"
benchmark_output="$(cd "$benchmark_output" && pwd)"
"$benchmark_binary" benchmark --seconds 5 --mbps 20 > "$benchmark_output/loopback-20.json"
"$benchmark_binary" benchmark --seconds 5 --mbps 80 > "$benchmark_output/loopback-80.json"
"$benchmark_binary" benchmark --seconds 5 --mbps 1000 > "$benchmark_output/loopback-1000.json"
"$benchmark_binary" benchmark --seconds 5 --mbps 20 --reconnect > "$benchmark_output/loopback-reconnect.json"
cd Benchmarks
BENCHMARK_DISABLE_JEMALLOC=true swift package benchmark --no-progress > "$benchmark_output/microbenchmarks.txt"
cd ..
python3 scripts/check-benchmarks.py "$benchmark_output"
