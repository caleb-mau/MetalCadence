// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "MetalCadenceConsumer",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "Smoke", dependencies: [.product(name: "MetalCadence", package: "MetalCadence")])]
)
