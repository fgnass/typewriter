// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Typewriter",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Typewriter",
            path: "Sources/Typewriter",
            swiftSettings: [.unsafeFlags(["-Onone"], .when(configuration: .debug))]
        )
    ]
)
