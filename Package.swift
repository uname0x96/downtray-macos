// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "InboxCore",
    platforms: [.macOS(.v14)],
    products: [
        // Business logic for Arrivals. No AppKit, no SwiftUI: a UI, a CLI, a test or an
        // agent drives it by sending events and reading the model.
        .library(name: "InboxCore", targets: ["InboxCore"]),
        // Headless driver: runs the presenter in-process, or attached to the running app.
        .executable(name: "inbox-cli", targets: ["inbox-cli"]),
    ],
    dependencies: [
        // Spotify's Mobius loop: update(model, event) -> Next(model, effects), effect routing, test specs.
        .package(url: "https://github.com/spotify/Mobius.swift", from: "0.8.0"),
    ],
    targets: [
        .target(
            name: "InboxCore",
            dependencies: [.product(name: "MobiusCore", package: "Mobius.swift")]
        ),
        .executableTarget(name: "inbox-cli", dependencies: ["InboxCore"]),
        .testTarget(
            name: "InboxCoreTests",
            dependencies: [
                "InboxCore",
                .product(name: "MobiusTest", package: "Mobius.swift"),
            ]
        ),
    ]
)
