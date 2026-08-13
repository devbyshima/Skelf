// The bundle that holds Skelf's runtime resources (art-map.json, skelf-menubar.pdf).

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

/// Skelf's version strings, read from the bundle's Info.plist (the single source of truth is
/// `SKELF_VERSION` in build.sh, which writes `CFBundleShortVersionString`). Plain `swift build`
/// runs have no Info.plist, so these report "dev"/"0".
var skelfShortVersion: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev" }
var skelfBuildVersion: String { (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0" }

/// Which release channel this build came from — stamped into Info.plist by build.sh
/// (`SKELF_CHANNEL`). See RELEASING.md.
enum ReleaseChannel: String {
    case production, beta, dev
    var label: String {
        switch self {
        case .production: return "Production"
        case .beta: return "Beta"
        case .dev: return "Development"
        }
    }
}

/// A plain `swift build` run has no Info.plist, so it reports `.dev` — which is also what an
/// untagged local `./build.sh` gets unless it passes SKELF_CHANNEL.
var skelfReleaseChannel: ReleaseChannel {
    ReleaseChannel(rawValue: (Bundle.main.infoDictionary?["SKELFReleaseChannel"] as? String) ?? "") ?? .dev
}
