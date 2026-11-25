// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "MetalCadence",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MetalCadence", targets: ["MetalCadence"])],
    targets: [.target(name: "MetalCadence", publicHeadersPath: "include",
                      linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("Metal"), .linkedFramework("QuartzCore"), .linkedFramework("MetalFX"), .linkedFramework("VideoToolbox"), .linkedFramework("CoreVideo"), .linkedFramework("CoreMedia"), .linkedFramework("AVFoundation"), .linkedFramework("IOKit"), .linkedFramework("AudioToolbox")])],
    cxxLanguageStandard: .cxx20
)
