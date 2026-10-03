// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Lightray",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "lightray-host", targets: ["lightray-host"]),
        .executable(name: "lightray-client", targets: ["lightray-client"]),
    ],
    dependencies: [
        // The protocol and what the apps share with an iOS client.
        .package(path: "../apple"),
    ],
    targets: [
        // Swift 5 mode, where framework callbacks meet dispatch queues.
        .executableTarget(
            name: "lightray-host",
            dependencies: [.product(name: "LightrayCore", package: "apple")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "lightray-client",
            dependencies: [.product(name: "LightrayCore", package: "apple")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
