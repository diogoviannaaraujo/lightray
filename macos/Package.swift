// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Lightray",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "LightrayCore", targets: ["LightrayCore"]),
        .executable(name: "lightray-host", targets: ["lightray-host"]),
        .executable(name: "lightray-client", targets: ["lightray-client"]),
    ],
    targets: [
        // The protocol, with no I/O and no platform frameworks beyond CryptoKit.
        .target(name: "LightrayCore"),
        // What both Mac executables share: the socket, the key map, pairing storage, VideoToolbox.
        // Swift 5 mode here and below, where framework callbacks meet dispatch queues.
        .target(
            name: "LightrayMac",
            dependencies: ["LightrayCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "lightray-host",
            dependencies: ["LightrayCore", "LightrayMac"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "lightray-client",
            dependencies: ["LightrayCore", "LightrayMac"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "LightrayCoreTests", dependencies: ["LightrayCore"]),
        .testTarget(name: "LightrayMacTests", dependencies: ["LightrayCore", "LightrayMac"]),
    ]
)
