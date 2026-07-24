// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "FixtureWorkspace",
    products: [.library(name: "Demo", targets: ["Demo"])],
    targets: [
        .target(name: "Demo"),
        .testTarget(name: "DemoTests", dependencies: ["Demo"])
    ]
)
