// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenClawMenuBar",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "OpenClawMenuBar",
            dependencies: [],
            path: "Sources",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
