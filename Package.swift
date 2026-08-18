// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NightShifter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NightShifter",
            path: "Sources/NightShifter"
        )
    ]
)
