// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DefiBar",
    defaultLocalization: "en",
    platforms: [.macOS("15.4")],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .executableTarget(
            name: "DefiBar",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            resources: [.process("Resources")]
        )
    ]
)
