// swift-tools-version:6.2
// Lightray protocol v0 — proof of concept. macOS only, no library dependencies.
// See README.md for what this PoC does and does not cover.
import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableExperimentalFeature("Lifetimes"),
]

let package = Package(
    name: "LightrayPoC",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LightrayCore", targets: ["LightrayCore"]),
        .library(name: "LightrayCrypto", targets: ["LightrayCrypto"]),
        .library(name: "LightrayEngine", targets: ["LightrayEngine"]),
        .library(name: "LightrayRuntime", targets: ["LightrayRuntime"]),
        .library(name: "LightrayTestSupport", targets: ["LightrayTestSupport"]),
        .executable(name: "lightray-poc", targets: ["lightray-poc"]),
    ],
    targets: [
        // Sans-IO core: no sockets, no threads, no clocks inside the state machines.
        .target(name: "LightrayCore", swiftSettings: settings),
        .target(name: "LightrayCrypto", dependencies: ["LightrayCore"], swiftSettings: settings),
        .target(name: "LightrayEngine", dependencies: ["LightrayCore", "LightrayCrypto"], swiftSettings: settings),
        // The only module that touches Darwin sockets, kqueue and threads.
        .target(name: "LightrayRuntime", dependencies: ["LightrayEngine"], swiftSettings: settings),
        .target(name: "LightrayTestSupport", dependencies: ["LightrayEngine"], swiftSettings: settings),
        // The demo borrows TestSupport's synthetic frame source: the library holds no
        // encoders, so a demo needs something to stand in for one.
        .executableTarget(name: "lightray-poc", dependencies: ["LightrayRuntime", "LightrayTestSupport"], swiftSettings: settings),

        .testTarget(name: "LightrayCoreTests", dependencies: ["LightrayCore", "LightrayTestSupport"], swiftSettings: settings),
        .testTarget(name: "LightrayCryptoTests", dependencies: ["LightrayCrypto"], swiftSettings: settings),
        .testTarget(name: "LightrayEngineTests", dependencies: ["LightrayEngine", "LightrayTestSupport"], swiftSettings: settings),
        .testTarget(name: "LightrayScenarioTests", dependencies: ["LightrayTestSupport"], swiftSettings: settings),
        .testTarget(name: "LightrayLoopbackTests", dependencies: ["LightrayRuntime", "LightrayTestSupport"], swiftSettings: settings),
    ]
)
