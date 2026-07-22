// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SentryNotch",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure, platform-agnostic logic — unit-tested.
        .target(name: "SentryNotchCore", path: "Sources/SentryNotchCore"),
        .executableTarget(
            name: "SentryNotch",
            dependencies: ["SentryNotchCore"],
            path: "Sources/SentryNotch"
        ),
        // Standalone test runner (no XCTest — this box has CommandLineTools,
        // not full Xcode). Run with: swift run SentryNotchTests
        .executableTarget(
            name: "SentryNotchTests",
            dependencies: ["SentryNotchCore"],
            path: "Tests/SentryNotchTests"
        ),
        // Regenerates Resources/SentryNotch.icns from the shield mark.
        .executableTarget(name: "makeicon", path: "tools/makeicon"),
    ]
)
