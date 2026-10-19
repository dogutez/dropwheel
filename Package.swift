// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Dropwheel",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Dropwheel", targets: ["Dropwheel"]),
        .executable(name: "dropwheel-cli", targets: ["dropwheel-cli"]),
    ],
    dependencies: [
        // Updates only. Network access stays inside Sparkle's own downloader XPC service;
        // the app itself keeps no network entitlement.
        // 2.10.0 or later: every published Sparkle security advisory is fixed in 2.9.6.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // Conversion engine: pure, UI-free, nonisolated so the caller decides where work runs.
        .target(name: "DropwheelCore"),
        // Menu-bar agent: AppKit + SwiftUI, main actor by default.
        .executableTarget(
            name: "Dropwheel",
            dependencies: ["DropwheelCore", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.defaultIsolation(MainActor.self)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // Headless driver for the engine, used for testing conversions from the shell.
        .executableTarget(name: "dropwheel-cli", dependencies: ["DropwheelCore"]),
        .testTarget(name: "DropwheelCoreTests", dependencies: ["DropwheelCore"]),
    ]
)
