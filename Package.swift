// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PlanGate",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PlanGateCore", targets: ["PlanGateCore"])
    ],
    dependencies: [
        .package(path: "Packages/LlamaBinary")
    ],
    targets: [
        .target(
            name: "PlanGateCore",
            dependencies: [
                .product(name: "LlamaBinary", package: "LlamaBinary")
            ],
            path: "PlanGate",
            exclude: [
                "PlanGateApp.swift",
                "Presentation",
                "Assets.xcassets",
                "Resources"
            ]
        ),
        .testTarget(
            name: "PlanGateCoreTests",
            dependencies: ["PlanGateCore"],
            path: "PlanGateTests"
        )
    ]
)
