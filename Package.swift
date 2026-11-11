// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeHandoff",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HandoffCore", targets: ["HandoffCore"]),
        .executable(name: "claude-handoff", targets: ["claude-handoff"]),
        .executable(name: "ClaudeHandoff", targets: ["ClaudeHandoff"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
    ],
    targets: [
        .target(name: "HandoffCore"),
        .executableTarget(name: "claude-handoff", dependencies: ["HandoffCore"]),
        .executableTarget(
            name: "ClaudeHandoff",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "HandoffCoreTests", dependencies: ["HandoffCore"], exclude: ["Fixtures"]),
    ]
)
