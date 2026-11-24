// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PingGlass",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "PingGlass", targets: ["PingGlassApp"])
    ],
    targets: [
        .executableTarget(
            name: "PingGlassApp",
            path: "PingGlassApp",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "PingGlassTests",
            dependencies: ["PingGlassApp"],
            path: "Tests/PingGlassTests"
        )
    ]
)
