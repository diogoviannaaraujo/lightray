// swift-tools-version:6.2
// Checks the Definition's benchmark setup: package-benchmark, path-dependent on ../
import PackageDescription

let package = Package(
    name: "SpikesBenchmarks",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../"),
        .package(url: "https://github.com/ordo-one/package-benchmark", from: "1.27.0"),
    ],
    targets: [
        .executableTarget(
            name: "CursorBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "SpikeCursor", package: "Spikes"),
                .product(name: "SpikeProbes", package: "Spikes"),
            ],
            path: "Benchmarks/CursorBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "package-benchmark")]
        ),
    ]
)
