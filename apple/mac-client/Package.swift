// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "LightrayClient",
    platforms: [.macOS(.v27)],
    products: [.executable(name: "lightray-client", targets: ["lightray-client"])],
    dependencies: [.package(path: "../core")],
    targets: [
        .executableTarget(name: "lightray-client",
                          dependencies: [.product(name: "LightrayCore", package: "core")],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
