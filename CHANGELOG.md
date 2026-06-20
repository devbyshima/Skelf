# Changelog

All notable changes to Skelf are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/devbyshima/Skelf/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/devbyshima/Skelf/releases/tag/v1.3.0
[1.2.0]: https://github.com/devbyshima/Skelf/releases/tag/v1.2.0
[1.1.0]: https://github.com/devbyshima/Skelf/releases/tag/v1.1.0
[1.0.1]: https://github.com/devbyshima/Skelf/releases/tag/v1.0.1
[1.0.0]: https://github.com/devbyshima/Skelf/releases/tag/v1.0.0
