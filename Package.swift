// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "opencode-usage-touchbar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "opencode-usage-touchbar", targets: ["OpenCodeUsageTouchBar"])
    ],
    targets: [
        .executableTarget(name: "OpenCodeUsageTouchBar"),
        .testTarget(
            name: "OpenCodeUsageTouchBarTests",
            dependencies: ["OpenCodeUsageTouchBar"]
        )
    ]
)