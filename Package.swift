// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LimitBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "LimitBar", path: "Sources/LimitBar"),
        // Swift Testing's macros live outside the default plugin path when only the Command Line
        // Tools are installed (no Xcode).
        .testTarget(name: "LimitBarTests", dependencies: ["LimitBar"], path: "Tests/LimitBarTests",
                    swiftSettings: [.unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"])]),
    ]
)
