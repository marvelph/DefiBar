// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DefiBar",
    defaultLocalization: "en",
    platforms: [.macOS("15.4")],
    targets: [.executableTarget(name: "DefiBar", resources: [.process("Resources")])]
)
