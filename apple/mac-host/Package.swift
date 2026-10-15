// swift-tools-version: 6.4
import PackageDescription

let core: Target.Dependency = .product(name: "LightrayCore", package: "core")
let settings: [SwiftSetting] = [.swiftLanguageMode(.v5)]
let package = Package(
    name: "LightrayHost",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "lightray-host", targets: ["lightray-host"]),
        .executable(name: "lightray-host-app", targets: ["lightray-host-app"]),
    ],
    dependencies: [.package(path: "../core")],
    targets: [
        .target(name: "LightrayHostSupport", dependencies: [core], swiftSettings: settings),
        .target(name: "LightrayHostRuntime", dependencies: [core], swiftSettings: settings),
        .executableTarget(name: "lightray-host", dependencies: [core, "LightrayHostRuntime", "LightrayHostSupport"], swiftSettings: settings),
        .executableTarget(name: "lightray-host-app", dependencies: [core, "LightrayHostSupport"], swiftSettings: settings),
        .testTarget(name: "LightrayHostTests", dependencies: ["LightrayHostRuntime", "LightrayHostSupport"], swiftSettings: settings),
        .testTarget(name: "LightrayDesktopTests", dependencies: ["lightray-host-app", "LightrayHostSupport"], swiftSettings: settings),
    ]
)
