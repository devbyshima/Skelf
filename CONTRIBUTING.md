# Contributing to Skelf

Thanks for your interest in Skelf! It's a small, single-target native macOS app, so
contributing is straightforward.

## Requirements

- **macOS 26+** (Skelf adopts Liquid Glass and targets the macOS 26 SDK).
- **Xcode 26+** — needed for the macOS 26 SDK and SwiftUI's macro plugin.

## Build & run

Two ways, both from the repo root:

```bash
# 1. Open the package in Xcode and hit Run
open Package.swift

# 2. Or build the fully bundled, ad-hoc-signed Skelf.app from the command line
./build.sh && open Skelf.app
```

`swift build` also works. `build.sh` is the one that produces a real `.app` (icon,
`Info.plist`, menu-bar resources) and locates Xcode's SwiftUI macro plugin for plain
`swiftc`.

## Project layout

The app is one SwiftPM target split into focused files under `Sources/Skelf/`:

| File | Contents |
|------|----------|
| `Skills.swift` | skill model, on-disk store, FSEvents watcher, favorites, folder tree |
| `AppSupport.swift` | palette, animation, sounds, appearance, global hot-key, settings |
| `Art.swift` | GitHub verification, avatar + painting fetching/caching |
| `Cards.swift` | grid item views (art view, cards, glass controls) |
| `Markdown.swift` | fonts, frontmatter, GitHub-style markdown rendering |
| `Detail.swift` | two-column skill detail view + menu helpers |
| `Grid.swift` | collection view, adaptive flow layout, grid controller |
| `Navigation.swift` | SwiftUI shell, observable model, Settings, representables |
| `MenuBar.swift` | menu-bar popover, toast, painting panel, controls |
| `HoverTip.swift` | shared Liquid Glass hover tip shown over skill cards |
| `App.swift` | AppDelegate, status item, menus, `@main` entry |
| `Updater.swift` | built-in auto-update (GitHub Releases check, SHA-256 verify, in-place install) |
| `Bundle+Skelf.swift` | resource-bundle resolver (`Bundle.module` vs `Bundle.main`) |

Runtime resources (`art-map.json`, `skelf.svg`) live in `Sources/Skelf/Resources/` and are
loaded via `skelfResourceBundle` so both SwiftPM (`Bundle.module`) and `build.sh`
(`Bundle.main`) work. App-packaging assets (`Skelf.icns`, `AppIcon/`) stay in `Resources/`.

## Branches

`main` is the trunk — **every new feature starts here**, on a short-lived branch PR'd into main.

When a version is feature-complete it gets a `release/X.Y` branch, which stabilizes into a beta
and then a production release. Those branches take **bug fixes only, never new features**.

| Your change | Base your branch on | Merge into |
|---|---|---|
| A new feature or improvement | `main` | `main` |
| A bug that only exists on main | `main` | `main` |
| A bug that shipped in a release | the **oldest** `release/X.Y` that has it | that release branch |

If your fix goes to a release branch, it also has to reach every newer release branch and `main`,
or it comes back as a regression when people upgrade. A maintainer handles that propagation — but
say so in the PR, so it doesn't get missed.

Two rules that keep this working:

- **Never merge `main` into a release branch.** That drags features into a stabilizing version.
  Traffic only ever flows release branch → newer release branch → main.
- **Don't edit `SKELF_VERSION` in `build.sh`.** It's the single source of truth for the version and
  the release workflows own it.

If a feature isn't finished but you'd like it on main anyway, put it behind a feature flag
(`Sources/Skelf/FeatureFlags.swift`) so it ships dark. Flags are temporary: delete the flag and
its branches when the feature goes out.

The whole flow — cutting a release, running a beta, promoting, hotfixes — is written out with
commands in [RELEASING.md](RELEASING.md).

## Before you open a PR

- Keep the diff focused; match the surrounding style.
- Run **SwiftLint** if you have it (`brew install swiftlint && swiftlint`). The config is
  intentionally lenient.
- Make sure it builds: `swift build` **and** `./build.sh`.
- Update `CHANGELOG.md` under "Unreleased" for anything user-facing — that section becomes the
  release notes verbatim, so write it for a user, not for a reviewer.

## Reporting bugs / requesting features

Open an issue using the templates. Include your macOS version and steps to reproduce.
