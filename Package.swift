// swift-tools-version: 5.10
import PackageDescription

let strictConcurrency: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency")
]

let package = Package(
    name: "GlowTop",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "GlowTopCore",
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "glowtop-probe",
            dependencies: ["GlowTopCore"],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "GlowTopApp",
            dependencies: ["GlowTopCore"],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "GlowTopCoreTests",
            dependencies: ["GlowTopCore"],
            swiftSettings: strictConcurrency
        ),
    ]
)
