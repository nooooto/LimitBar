// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LimitBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "LimitBar", path: "Sources/LimitBar")
    ]
)
