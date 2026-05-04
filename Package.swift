// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "duck-wispr",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "DuckWisprLib",
            path: "Sources/DuckWisprLib",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "duck-wispr",
            dependencies: ["DuckWisprLib"],
            path: "Sources/DuckWispr"
        ),
        .testTarget(
            name: "DuckWisprTests",
            dependencies: ["DuckWisprLib"],
            path: "Tests/DuckWisprTests"
        ),
    ]
)
