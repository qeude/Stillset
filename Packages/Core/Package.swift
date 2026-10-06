// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.macOS("27.0")],
    products: [.library(name: "StillsetCore", targets: ["StillsetCore"])],
    targets: [
        .target(name: "StillsetCore", path: "Sources"),
        .testTarget(name: "StillsetCoreTests", dependencies: ["StillsetCore"], path: "Tests/StillsetCoreTests")
    ]
)
