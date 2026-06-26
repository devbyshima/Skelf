// swift-tools-version: 6.0
import PackageDescription

// Skelf is a SwiftUI + AppKit menu-bar app. Open this package in Xcode (File ▸ Open…) and
// run, or `swift build`. For a fully bundled, ad-hoc-signed Skelf.app (icon, Info.plist),
// use ./build.sh — it also locates Xcode's SwiftUI macro plugin for command-line swiftc.
let package = Package(
    name: "Skelf",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Skelf",
            path: "Sources/Skelf",
            resources: [
                .process("Resources/art-map.json"),
                .process("Resources/skelf-menubar.pdf"),
            ]
        ),
    ],
    // The app is written for the Swift 5 language mode (its singletons predate Swift 6
    // strict concurrency); build.sh likewise passes -swift-version 5.
    swiftLanguageModes: [.v5]
)
