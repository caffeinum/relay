// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Chat",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "ChatCore",
            path: "Sources/ChatCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Chat",
            dependencies: ["ChatCore"],
            path: "Sources/Chat",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "chatctl",
            dependencies: ["ChatCore"],
            path: "Sources/chatctl",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ChatCoreTests",
            dependencies: ["ChatCore"],
            path: "Tests/ChatCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
