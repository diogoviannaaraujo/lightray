// swift-tools-version:6.2
import PackageDescription

let modules = ["LightrayPrimitives", "LightrayWire", "LightrayStats", "LightrayCrypto", "LightrayStreams", "LightraySession", "LightrayTransport", "Lightray", "LightrayDebugOverlay", "LightrayTestSupport"]
let settings: [SwiftSetting] = [.enableUpcomingFeature("ExistentialAny"), .enableExperimentalFeature("Lifetimes")]
func module(_ name: String, _ dependencies: [Target.Dependency] = []) -> Target { .target(name: name, dependencies: dependencies, swiftSettings: settings) }
let package = Package(
    name: "Lightray", platforms: [.macOS(.v26)], products: modules.map { .library(name: $0, targets: [$0]) } + [.executable(name: "lightray-demo", targets: ["LightrayDemo"])],
    targets: [
        module("LightrayPrimitives"),
        module("LightrayWire", ["LightrayPrimitives"]),
        module("LightrayStats", ["LightrayPrimitives"]),
        module("LightrayCrypto", ["LightrayPrimitives", "LightrayWire"]),
        module("LightrayStreams", ["LightrayPrimitives", "LightrayWire", "LightrayStats"]),
        module("LightraySession", ["LightrayPrimitives", "LightrayWire", "LightrayStats", "LightrayCrypto", "LightrayStreams"]),
        module("LightrayTransport", ["LightraySession"]),
        module("Lightray", ["LightraySession", "LightrayTransport"]),
        module("LightrayDebugOverlay", ["LightrayStats"]),
        module("LightrayTestSupport", ["LightraySession"]),
        .executableTarget(name: "LightrayDemo", dependencies: ["Lightray", "LightrayTestSupport"], swiftSettings: settings),
        .testTarget(name: "LightrayTests", dependencies: modules.map { .byName(name: $0) }, resources: [.copy("Vectors")], swiftSettings: settings),
    ])
