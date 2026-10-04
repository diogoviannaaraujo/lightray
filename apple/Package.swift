// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "LightrayCore",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [
        .library(name: "LightrayCore", targets: ["LightrayCore"]),
    ],
    targets: [
        // The protocol, with no I/O, and what the apps on both platforms share around it: the
        // socket, pairing, VideoToolbox, showing the video and running a client.
        .target(name: "LightrayCore"),
        .testTarget(name: "LightrayCoreTests", dependencies: ["LightrayCore"], resources: [.copy("Fixtures")]),
    ]
)
