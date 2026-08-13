// Feature flags — the mechanism that lets unfinished work land on `main` while staying dark in
// production builds, so a half-built feature never blocks cutting a release branch.
//
// A flag is on when: the user set an explicit override, else when the running build's channel is
// in the flag's `enabledIn` set. Overrides persist in UserDefaults, so they survive relaunch and
// can be set without any UI:
//
//   defaults write dev.fulltime.skelf flag.skillGraph -bool YES     # force on
//   defaults delete dev.fulltime.skelf flag.skillGraph              # back to the channel default
//
// Non-production builds also list every declared flag in Settings ▸ Updates with a checkbox.
//
// Flags are temporary by construction: once a feature ships to production, delete its entry here
// and delete the `if FeatureFlags.isOn(...)` branches with it. See RELEASING.md ▸ Feature flags.

import Foundation

struct FeatureFlag: Identifiable {
    /// Short camelCase name; the UserDefaults key is `flag.<name>`.
    let name: String
    let title: String
    let summary: String
    /// Channels where the flag is on unless the user overrides it. Add `.production` only as the
    /// last step before deleting the flag entirely.
    let enabledIn: Set<ReleaseChannel>

    var id: String { name }
    var key: String { "flag." + name }
}

enum FeatureFlags {
    /// Every flag the app knows about. Empty is the healthy steady state — entries live here only
    /// while a feature is mid-flight.
    ///
    /// Declare one like this, then gate the code with `if FeatureFlags.isOn("skillGraph")`:
    ///
    ///     FeatureFlag(name: "skillGraph",
    ///                 title: "Skill Graph",
    ///                 summary: "Force-directed view of how skills reference each other.",
    ///                 enabledIn: [.dev, .beta]),
    static let all: [FeatureFlag] = []

    /// Whether `name` is currently on. Unknown names are always off, so deleting a flag's
    /// declaration safely disables any gate that outlived it.
    static func isOn(_ name: String) -> Bool {
        guard let flag = all.first(where: { $0.name == name }) else { return false }
        if let override = UserDefaults.standard.object(forKey: flag.key) as? Bool { return override }
        return flag.enabledIn.contains(skelfReleaseChannel)
    }

    /// Set (`true`/`false`) or clear (`nil`, back to the channel default) a user override.
    static func setOverride(_ on: Bool?, for flag: FeatureFlag) {
        if let on = on {
            UserDefaults.standard.set(on, forKey: flag.key)
        } else {
            UserDefaults.standard.removeObject(forKey: flag.key)
        }
    }

    /// True when the user has pinned this flag rather than inheriting the channel default.
    static func hasOverride(_ flag: FeatureFlag) -> Bool {
        UserDefaults.standard.object(forKey: flag.key) != nil
    }
}
