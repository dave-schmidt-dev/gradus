// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GradusKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "GradusKit", targets: ["GradusKit"]),
    ],
    targets: [
        .target(
            name: "GradusKit",
            path: "Sources/GradusKit"
        ),
        .testTarget(
            name: "GradusKitTests",
            dependencies: ["GradusKit"],
            path: "Tests/GradusKitTests",
            resources: [
                .copy("Fixtures/golden-v2-snapshot.json"),
                .copy("Fixtures/signal-levels.json"),
                .copy("Fixtures/percent-format.json"),
            ]
        ),
    ]
)
