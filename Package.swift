// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DevDeck",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "DevDeck",
            path: "Sources/DevDeck"
        ),
        .testTarget(
            name: "DevDeckTests",
            dependencies: ["DevDeck"],
            path: "Tests/DevDeckTests"
        ),
    ]
)
