#!/usr/bin/env bash
# Everything that has to be green. macOS only.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> swift build"
swift build

echo "==> swift test (debug: behaviour, including the loopback suite)"
swift test

# The zero-allocation target is about the shipped code. A debug build boxes
# closures and keeps retain/release traffic that optimisation removes, so it
# reports allocations for code that does not allocate; the assertion only bites
# in release.
echo "==> swift test -c release --filter AllocationTests (the zero-allocation target)"
swift test -c release --filter AllocationTests

# The plan's 60-second scenarios are gated so the normal run stays quick.
if [[ "${LIGHTRAY_LONG_SCENARIOS:-0}" == "1" ]]; then
  echo "==> swift test --filter SteadyStateTests (60 s scenarios)"
  LIGHTRAY_LONG_SCENARIOS=1 swift test --filter SteadyStateTests
fi

echo "==> benchmark smoke run"
# jemalloc is not installed, and package-benchmark's malloc metric is unusable
# without it anyway (see Docs/benchmarks.md).
(
  cd Benchmarks
  export BENCHMARK_DISABLE_JEMALLOC=true
  swift build -c release
  swift package benchmark --target WireBenchmarks --no-progress > /dev/null
)

echo "==> lightray-poc selftest (mac -> mac over 127.0.0.1)"
swift build -c release --product lightray-poc
.build/release/lightray-poc selftest --seconds 8

echo
echo "all green"
