// swift-tools-version:6.2
// Phase-0 spikes for Lightray: each probe turns a supposition in Definition.md
// into a measured fact. Run `swift run -c release spikes all` (see README.md).
import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableExperimentalFeature("Lifetimes"),
]

let package = Package(
    name: "Spikes",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SpikeCursor", targets: ["SpikeCursor"]),
        .library(name: "SpikeProbes", targets: ["SpikeProbes"]),
        .executable(name: "spikes", targets: ["spikes"]),
    ],
    targets: [
        // Separate module so @inlinable + ~Escapable is exercised across a module boundary.
        .target(name: "SpikeCursor", swiftSettings: settings),
        .target(name: "SpikeProbes", dependencies: ["SpikeCursor"], swiftSettings: settings),
        .executableTarget(name: "spikes", dependencies: ["SpikeProbes"], swiftSettings: settings),
        .testTarget(name: "SpikeTests", dependencies: ["SpikeProbes", "SpikeCursor"], swiftSettings: settings),
    ]
)
