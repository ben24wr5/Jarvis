// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OLED",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "ObjCSupport",
            path: "Sources/ObjCSupport",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "OLED",
            dependencies: ["ObjCSupport"],
            path: "Sources/OLED"
        )
    ]
)
