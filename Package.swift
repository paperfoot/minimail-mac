// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Minimail",
    platforms: [
        .macOS("26.0"),
    ],
    targets: [
        .executableTarget(
            name: "Minimail",
            path: "Sources/Minimail",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
    ]
)
