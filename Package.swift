// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveTrans",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "LiveTrans",
            path: "Sources/LiveTrans",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
