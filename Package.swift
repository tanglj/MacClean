// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacCleanCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MacCleanCore", targets: ["MacCleanCore"]),
        .executable(name: "MacCleanApp", targets: ["MacCleanApp"])
    ],
    targets: [
        .target(name: "MacCleanCore", resources: [.process("Resources")]),
        .executableTarget(name: "MacCleanApp", dependencies: ["MacCleanCore"]),
        .testTarget(name: "MacCleanCoreTests", dependencies: ["MacCleanCore"])
    ]
)
