// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "RelayCore",
            path: "Sources/RelayCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Relay",
            dependencies: ["RelayCore"],
            path: "Sources/Relay",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "relayctl",
            dependencies: ["RelayCore"],
            path: "Sources/relayctl",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RelayCoreTests",
            dependencies: ["RelayCore"],
            path: "Tests/RelayCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
