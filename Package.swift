// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PTZPad",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PTZPad",
            path: "Sources/PTZPad",
            linkerSettings: [
                .linkedFramework("GameController"),
                .linkedFramework("Network"),
            ]
        )
    ]
)
