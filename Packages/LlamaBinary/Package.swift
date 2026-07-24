// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LlamaBinary",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LlamaBinary", targets: ["llama"])
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b9999/llama-b9999-xcframework.zip",
            checksum: "edc986f1e646d69fc331074a57b909082e9172c0bb09eef06ade6afdf4496c5a"
        )
    ]
)
