// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OrchardApp",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "OrchardServiceLifecycle",
            targets: ["OrchardServiceLifecycle"]
        ),
        .executable(
            name: "orchard-service",
            targets: ["OrchardServiceCLI"]
        ),
        .executable(
            name: "Orchard",
            targets: ["OrchardApp"]
        )
    ],
    targets: [
        .target(name: "OrchardServiceLifecycle"),
        .executableTarget(
            name: "OrchardServiceCLI",
            dependencies: ["OrchardServiceLifecycle"]
        ),
        .executableTarget(name: "OrchardApp"),
        .testTarget(
            name: "OrchardServiceLifecycleTests",
            dependencies: ["OrchardServiceLifecycle"]
        )
    ]
)
