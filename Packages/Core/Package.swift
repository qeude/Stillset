// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Core",
    defaultLocalization: "en",
    platforms: [.macOS("27.0")],
    products: [.library(name: "StillsetCore", targets: ["StillsetCore"])],
    targets: [
        .target(name: "StillsetCore", path: "Sources", resources: [.process("Resources")]),
        .testTarget(name: "StillsetCoreTests", dependencies: ["StillsetCore"], path: "Tests/StillsetCoreTests")
    ]
)
