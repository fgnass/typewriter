// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Typewriter",
    platforms: [.macOS(.v13)],
    targets: [
        // Carriage geometry and hardware colors, shared by the app and the image generator.
        .target(name: "Carriage", path: "Sources/Carriage"),
        .executableTarget(
            name: "Typewriter",
            dependencies: ["Carriage"],
            path: "Sources/Typewriter",
            swiftSettings: [.unsafeFlags(["-Onone"], .when(configuration: .debug))]
        ),
        // Makes the hardware images for all colors at build time (see build.sh).
        .executableTarget(
            name: "hardware-assets",
            dependencies: ["Carriage"],
            path: "Sources/HardwareAssets"
        ),
    ]
)
