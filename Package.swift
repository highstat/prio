// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Prio",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Prio", targets: ["Prio"]),
    ],
    targets: [
        // Pure decision logic. Foundation only: no CoreAudio, no AppKit.
        .target(name: "PrioCore"),
        // CoreAudio implementation of PrioCore's AudioSystem protocol.
        .target(
            name: "PrioAudio",
            dependencies: ["PrioCore"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        // The menu bar app.
        .executableTarget(
            name: "Prio",
            dependencies: ["PrioCore", "PrioAudio"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(name: "PrioCoreTests", dependencies: ["PrioCore"]),
    ]
)
