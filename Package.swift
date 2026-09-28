// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JustRecorder",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "JustRecorder",
            path: "Sources/JustRecorder"
        )
    ]
)
