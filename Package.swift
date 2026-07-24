// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LocalAICodingHarness",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LocalAICodingHarnessCore", targets: ["LocalAICodingHarnessCore"])
    ],
    dependencies: [
        .package(path: "Packages/LlamaBinary")
    ],
    targets: [
        .target(
            name: "LocalAICodingHarnessCore",
            dependencies: [
                .product(name: "LlamaBinary", package: "LlamaBinary")
            ],
            path: "codingHarness",
            exclude: [
                "codingHarnessApp.swift",
                "Presentation",
                "Assets.xcassets",
                "Resources"
            ]
        ),
        .testTarget(
            name: "LocalAICodingHarnessCoreTests",
            dependencies: ["LocalAICodingHarnessCore"],
            path: "codingHarnessTests"
        )
    ]
)
