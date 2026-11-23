// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AntigravityUsageMonitor",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "UsageCore",
            targets: ["UsageCore"]
        ),
        .executable(
            name: "AntigravityUsageMonitor",
            targets: ["AntigravityUsageMonitor"]
        ),
    ],
    targets: [
        .target(
            name: "UsageCore",
            path: "Sources/UsageCore"
        ),
        .executableTarget(
            name: "AntigravityUsageMonitor",
            dependencies: ["UsageCore"],
            path: "Sources/AntigravityUsageMonitor"
        ),
        .executableTarget(
            name: "UsageCoreSelfTest",
            dependencies: ["UsageCore"],
            path: "Sources/UsageCoreSelfTest"
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            path: "Tests/UsageCoreTests"
        ),
    ]
)
