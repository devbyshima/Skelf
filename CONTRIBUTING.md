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

## Before you open a PR

- Keep the diff focused; match the surrounding style.
- Run **SwiftLint** if you have it (`brew install swiftlint && swiftlint`). The config is
  intentionally lenient.
- Make sure it builds: `swift build` **and** `./build.sh`.
- Update `CHANGELOG.md` under "Unreleased" for anything user-facing.

## Reporting bugs / requesting features

Open an issue using the templates. Include your macOS version and steps to reproduce.
