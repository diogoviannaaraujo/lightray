// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReviewProbes",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../../../../macos")],
    targets: [.executableTarget(name: "ReviewProbes", dependencies: [.product(name: "LightrayCore", package: "macos")])]
)
