# Changelog

All notable changes to Skelf are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.5.2] - 2026-06-24

### Added

- Empty states in the main window — a search with no matches, an empty Favorites or folder, and a
  fresh install with no skills yet now show a clear message and guidance instead of a blank grid.

### Fixed

- The window's **New Folder** and **Settings** toolbar buttons no longer occasionally render on
  the wrong side (by the traffic lights) with a flicker — they're pinned to the trailing edge.

## [1.5.1] - 2026-06-24

### Fixed

- The **menu-bar icon** is now visible in release builds. It ships as a vector PDF template loaded
  through AppKit's standard template path, replacing a runtime-rasterized bitmap that rendered
  blank in the live status bar when the app was built against the macOS 26 SDK.

## [1.5.0] - 2026-06-21

### Changed

- In **Menu Bar Only** mode, **⌘Q** (and closing the window) tucks Skelf back into the menu bar
  instead of quitting, so the icon keeps running; in the regular windowed mode ⌘Q quits as usual.
  **Quit Completely** — in the menu-bar ⋯ menu and the app menu (⌥⌘Q) — always fully exits and
  removes the icon.
- With **Menu Bar Only** on, launching at login now opens just the menu-bar icon — the main
  window no longer pops up. Opening Skelf yourself still shows the window.
- The **Settings** window is rebuilt as classic macOS preferences — native toolbar tabs
  (General, Appearance, Intelligence, Updates) with native checkbox controls — instead of one
  long scrolling list.

## [1.4.0] - 2026-06-21

### Added

- One-click releasing: a **Cut Release** workflow (Actions → Run workflow) bumps the version,
  promotes the changelog, and pushes the tag — which `release.yml` then builds and publishes.

### Changed

- Skill detail page redesign: **Back, Copy and Favorite** moved into a transparent window
  toolbar, leveled with the traffic lights, over a taller full-bleed artwork banner.
- The banner now **ripples** (Metal shader) when a skill opens and when it's clicked; a click
  ripples, then the artwork popup **bounces in at the window centre**.
- Buttons animate only on click — a spring-pop that always returns to full size (no hover
  movement, and they can no longer get stuck shrunk).
- The on-device **EXPLANATION** (formerly "In Plain English") prewarms and prefetches its
  Foundation Models summary on card hover so it appears faster, and reads as one flowing
  sentence ("… — best for …").

### Fixed

- Detail cards now follow light/dark appearance changes instead of keeping their build-time
  colors.
- The window background no longer leaks as a strip above the banner.

## [1.3.0] - 2026-06-20

### Changed

- A look-and-feel revamp with Metal-shader and motion polish (all honoring Reduce Motion):
  - The artwork popup is rebuilt in SwiftUI — a fixed-size, ratio-preserving card in a thin
    Liquid-Glass frame with a Metal **ripple** shader that radiates on open and on click.
  - Skill cards gain a parallax artwork **zoom on hover** and a crossfade + **shimmer** sweep
    as each NASA image loads in.
  - Folders, skills, and the detail view **cascade in** with a staggered ease-out entrance.
  - Tactile **press feedback** on every button (card controls, Copy, detail sidebar), a green
    copy-confirmation wash, and an expanding ring when a skill is favorited.
  - A subtle legibility shadow on card and banner text over the space art.

## [1.2.0] - 2026-06-20

### Added

- On-device natural-language skill search. Type a task in plain words ("my emails keep
  landing in spam", "review my Swift for data races") and Skelf ranks the skills that fit,
  powered by Apple's Foundation Models — fully on-device, offline, and private. It augments
  the search box in both the main window and the menu-bar popover, and falls back to the
  existing substring search when Apple Intelligence is unavailable.
- Plain-English skill summaries. The detail view shows an on-device, jargon-light "in plain
  English" take on each skill beneath its raw description.
- An "On-Device AI Search" toggle in **Settings ▸ Intelligence** (default on).

### Changed

- Skill-card art is now public-domain space imagery from NASA, drawn from a hand-curated
  pool and assigned a distinct image per skill — replacing the Art Institute paintings.
  Clicking a card's banner now opens the full image edge-to-edge. Generated offline art
  remains the fallback when covers are off or a download fails.

## [1.1.0] - 2026-06-19

### Added

- Built-in auto-update. Skelf checks GitHub for a newer release on launch and once a day,
  verifies the download against the published `SHA256SUMS`, then swaps itself in place and
  relaunches. A "Check for Updates…" item (app menu and the popover's ⋯ menu) runs it on
  demand, and **Settings ▸ Updates** has an "Automatically Check for Updates" toggle.

## [1.0.1] - 2026-06-19

### Fixed

- Menu-bar icon never appeared in release builds. The Skelf mark was loaded straight from
  `skelf.svg` into a vector-only `NSImage`, which the live menu bar composites as blank; it's
  now rasterized to a bitmap template image (with an SF-symbol fallback) so the icon always shows.

## [1.0.0] - 2026-06-19

### Added

- Browse installed Claude Code skills as a grid of cards, each backed by a unique
  public-domain painting (Art Institute of Chicago) with a generated offline fallback.
- Per-creator auto-folders, a Favorites folder, and display-only folders you make yourself.
- Two-column skill detail with rendered SKILL.md and a centered painting panel.
- Global search across every folder and skill, identical in the window and the menu-bar popover.
- Menu-bar popover with a global ⌥⌘S toggle hot-key.
- Settings window (Launch at Login, Menu Bar Only, Global Shortcut, Appearance, painting
  covers, Refresh Painting Art, Reduce Motion, Play Sounds) and a full macOS menu bar.
- Live updates via an FSEvents watcher on the skill directories.
- A minimal Liquid Glass hover tip on cards (name, slash command, creator).
- CLI modes: `--version`, `--list`, `--copy`, `--open`, `--enter`, `--popover`.

### Changed

- Restructured from a single source file into focused files under `Sources/Skelf/`, added a
  SwiftPM `Package.swift` (opens in Xcode / `swift build`), CI, SwiftLint, and contributor docs.

[Unreleased]: https://github.com/devbyshima/Skelf/compare/v1.5.2...HEAD
[1.5.2]: https://github.com/devbyshima/Skelf/releases/tag/v1.5.2
[1.5.1]: https://github.com/devbyshima/Skelf/releases/tag/v1.5.1
[1.5.0]: https://github.com/devbyshima/Skelf/releases/tag/v1.5.0
[1.4.0]: https://github.com/devbyshima/Skelf/releases/tag/v1.4.0
[1.3.0]: https://github.com/devbyshima/Skelf/releases/tag/v1.3.0
[1.2.0]: https://github.com/devbyshima/Skelf/releases/tag/v1.2.0
[1.1.0]: https://github.com/devbyshima/Skelf/releases/tag/v1.1.0
[1.0.1]: https://github.com/devbyshima/Skelf/releases/tag/v1.0.1
[1.0.0]: https://github.com/devbyshima/Skelf/releases/tag/v1.0.0
