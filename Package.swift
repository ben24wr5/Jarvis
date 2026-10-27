// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OLED",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "OLED",
            path: "Sources/OLED"
        )
    ]
)
