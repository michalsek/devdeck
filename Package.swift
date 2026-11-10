// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DevDeck",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "DevDeckProtocol",
            path: "Sources/DevDeckProtocol"
        ),
        .executableTarget(
            name: "DevDeck",
            dependencies: ["DevDeckProtocol"],
            path: "Sources/DevDeck"
        ),
        .executableTarget(
            name: "devdeck-hook",
            dependencies: ["DevDeckProtocol"],
            path: "Sources/devdeck-hook"
        ),
        .testTarget(
            name: "DevDeckTests",
            dependencies: ["DevDeck", "DevDeckProtocol"],
            path: "Tests/DevDeckTests"
        ),
    ]
)
