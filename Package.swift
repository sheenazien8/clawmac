// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clawmac",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Clawmac",
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
