# Changelog

All notable changes to Skelf are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- CLI modes: `--list`, `--copy`, `--open`, `--popover`.

### Changed

- Restructured from a single source file into focused files under `Sources/Skelf/`, added a
  SwiftPM `Package.swift` (opens in Xcode / `swift build`), CI, SwiftLint, and contributor docs.

[Unreleased]: https://github.com/devbyshima/Skelf
