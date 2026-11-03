// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeAccountBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AccountCore"),
        .executableTarget(name: "ClaudeAccountBar", dependencies: ["AccountCore"]),
        .testTarget(name: "AccountCoreTests", dependencies: ["AccountCore"]),
    ],
    swiftLanguageModes: [.v5]
)
