// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GradusKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(name: "GradusKit", targets: ["GradusKit"])
    ],
    dependencies: [
        .package(path: "../../../apple_developer/diagnostics_contracts/swift")
    ],
    targets: [
        .target(
            name: "GradusKit",
            dependencies: [.product(name: "AppDiagnostics", package: "swift")],
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
                .copy("Fixtures/pace-labels.json")
            ]
        )
    ]
)
