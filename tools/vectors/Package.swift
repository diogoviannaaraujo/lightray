// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LightrayVectors",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "lightray-vectors", targets: ["lightray-vectors"]),
    ],
    targets: [
        .target(name: "LightrayVectors"),
        .executableTarget(name: "lightray-vectors", dependencies: ["LightrayVectors"]),
        .testTarget(
            name: "LightrayVectorsTests",
            dependencies: ["LightrayVectors"],
            exclude: ["Fixtures"]
        ),
    ]
)
