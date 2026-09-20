// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "LightrayBenchmarks", platforms: [.macOS(.v26)],
    dependencies: [
        .package(name: "lightray", path: "../"),
        .package(url: "https://github.com/ordo-one/package-benchmark", exact: "1.36.2"),
    ],
    targets: [
        .executableTarget(
            name: "LightrayBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "Lightray", package: "lightray"),
                .product(name: "LightrayCrypto", package: "lightray"),
                .product(name: "LightrayTestSupport", package: "lightray"),
            ], path: "Benchmarks/LightrayBenchmarks", swiftSettings: [.enableExperimentalFeature("Lifetimes")], plugins: [.plugin(name: "BenchmarkPlugin", package: "package-benchmark")])
    ])
