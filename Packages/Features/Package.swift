// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Features",
    platforms: [.macOS("27.0")],
    products: [.library(name: "StillsetFeatures", targets: ["StillsetFeatures"])],
    dependencies: [.package(path: "../Core")],
    targets: [
        .target(
            name: "StillsetFeatures",
            dependencies: [.product(name: "StillsetCore", package: "core")],
            path: "Sources"
        ),
        .testTarget(
            name: "StillsetFeaturesTests",
            dependencies: ["StillsetFeatures", .product(name: "StillsetCore", package: "core")],
            path: "Tests"
        )
    ]
)
