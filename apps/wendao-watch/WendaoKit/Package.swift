// swift-tools-version: 6.0
// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import PackageDescription

let package = Package(
    name: "WendaoKit",
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS(.v18),
        .watchOS(.v11),
        .macOS(.v15)
    ],
    products: [
        .library(name: "WendaoKit", targets: ["WendaoKit"])
    ],
    targets: [
        .target(
            name: "WendaoKit"
        ),
        .testTarget(
            name: "WendaoKitTests",
            dependencies: ["WendaoKit"]
        )
    ],
    swiftLanguageModes: [.v6]
)
