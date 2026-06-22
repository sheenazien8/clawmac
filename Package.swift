// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClawMac",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "ClawMac",
            dependencies: [],
            path: "Sources",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .define("SWIFT_PACKAGE"),
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
