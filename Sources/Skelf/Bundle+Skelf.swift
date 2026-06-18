// The bundle that holds Skelf's runtime resources (art-map.json, skelf.svg).

import Foundation

/// Resolves to the SwiftPM module bundle when built with `swift build` / Xcode (resources
/// are declared in Package.swift), and to the app bundle when built with `build.sh` (which
/// copies the same files into Skelf.app/Contents/Resources). `Bundle.module` only exists
/// under SwiftPM, so it's referenced behind `#if SWIFT_PACKAGE`.
var skelfResourceBundle: Bundle {
    #if SWIFT_PACKAGE
    return .module
    #else
    return .main
    #endif
}
