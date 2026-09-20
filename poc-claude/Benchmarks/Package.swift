// swift-tools-version:6.2
// Benchmarks live in their own package so the library itself has no dependencies.
import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableExperimentalFeature("Lifetimes"),
]

let package = Package(
    name: "LightrayBenchmarks",
    platforms: [.macOS(.v26)],
    dependencies: [
        // A path dependency is identified by its directory name, not its manifest name.
        .package(path: "../"),
        .package(url: "https://github.com/ordo-one/package-benchmark", from: "1.27.0"),
    ],
    targets: [
        .executableTarget(
            name: "WireBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "LightrayCore", package: "poc-claude"),
                .product(name: "LightrayCrypto", package: "poc-claude"),
            ],
            path: "Benchmarks/WireBenchmarks",
            swiftSettings: settings,
            plugins: [.plugin(name: "BenchmarkPlugin", package: "package-benchmark")]
        ),
        .executableTarget(
            name: "PipelineBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "LightrayEngine", package: "poc-claude"),
                .product(name: "LightrayTestSupport", package: "poc-claude"),
            ],
            path: "Benchmarks/PipelineBenchmarks",
            swiftSettings: settings,
            plugins: [.plugin(name: "BenchmarkPlugin", package: "package-benchmark")]
        ),
        .executableTarget(
            name: "TransportBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "LightrayRuntime", package: "poc-claude"),
                .product(name: "LightrayTestSupport", package: "poc-claude"),
            ],
            path: "Benchmarks/TransportBenchmarks",
            swiftSettings: settings,
            plugins: [.plugin(name: "BenchmarkPlugin", package: "package-benchmark")]
        ),
    ]
)
