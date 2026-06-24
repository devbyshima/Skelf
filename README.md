<div align="center">

<img src="Resources/AppIcon/Skelf-iOS-Default-128@2x.png" width="120" alt="Skelf app icon">

# Skelf

**A native macOS menu-bar app for browsing your installed Claude Code skills.**

Browse them as a grid, read a skill's rendered `SKILL.md`, and copy its slash command
(e.g. `/grill-me`) to paste into a cloud session.

[![Latest release](https://img.shields.io/github/v/release/devbyshima/Skelf?label=download&color=da7756)](https://github.com/devbyshima/Skelf/releases/latest)
[![Platform](https://img.shields.io/badge/macOS-26%2B-black)](#install)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI%20%2B%20AppKit-orange)](Package.swift)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

</div>

![Skelf — the grill-me skill open in detail: a NASA artwork banner, its rendered SKILL.md, and a one-click Copy for the /grill-me slash command](docs/screenshot.png)

Skelf reads the skills you've installed under your dev directory straight from disk and lays
them out as a grid of image-backed cards, grouped into a folder per creator. Open any card for
its full detail, hit **Copy**, and you've got `/<skill>` on the clipboard. It lives in the menu
bar (toggle from anywhere with **⌥⌘S**) or as a regular window, and updates itself in place.

Built with SwiftUI's `NavigationStack` and Liquid Glass toolbars hosting an AppKit grid and
detail view — one SwiftPM target, split into focused files under `Sources/Skelf/`.

## Features

- **Grid of cards** — each skill is a card backed by a unique public-domain **NASA space
  image** (drawn from a bundled pool, disk-cached), with a generated gradient + icon fallback
  when offline or covers are off. Cards reflow to any width, scale on hover, and squash on
  press; resting on one shows a minimal Liquid Glass hover tip (name, slash command, creator).
- **Auto-organized by creator** — skills group into a folder per owner automatically once an
  owner has two or more installed, with the creator's GitHub avatar on the folder tile.
  Singletons stay loose, and you can make your own folders (display-only — they never touch
  Claude's config).
- **Favorites** — toggle from a card's ★, a ⋯ menu, or the detail view; a pinned **Favorites**
  folder gathers them all.
- **Skill detail** — two columns under a full-bleed artwork banner: a scrollable, GitHub-style
  rendering of `SKILL.md` and a sticky sidebar (Source / Slash command / Details / Actions).
  The banner ripples (Metal shader) on open and on click; clicking it bounces the full artwork
  into the centre of the window.
- **On-device AI search** — type a task in plain words ("my emails keep landing in spam") and
  Skelf ranks the skills that fit, plus shows a plain-English summary of each one. Runs entirely
  on-device via Apple Intelligence, and falls back to substring search when it's unavailable.
- **Global search** — spans every folder and skill (name, description, category, creator),
  identical in the window and the menu bar.
- **Menu-bar popover** — Liquid Glass cards for your Favorites and menu-bar folders; copies
  `/<skill>` with a toast. Toggle it from anywhere with **⌥⌘S**.
- **Auto-detect** — an FSEvents watcher keeps the app live as skills are added, removed,
  enabled, disabled, or edited.
- **Self-updating** — checks GitHub for a newer release on launch and once a day, verifies the
  download against the published `SHA256SUMS`, then installs it in place and relaunches.

## Install

> [!IMPORTANT]
> Skelf requires **macOS 26 (Tahoe) or later** — it adopts Liquid Glass and targets the macOS
> 26 SDK.

1. Download `Skelf.dmg` from the [latest release](https://github.com/devbyshima/Skelf/releases/latest).
2. Open it and drag **Skelf** onto **Applications**.

> [!NOTE]
> **First launch:** Skelf isn't yet signed with an Apple Developer ID, so macOS blocks it the
> first time. Open **System Settings → Privacy & Security**, scroll to the bottom, click
> **Open Anyway**, then confirm **Open**. You only do this once. (The old right-click → Open
> shortcut no longer works on macOS 15+.) Launch at Login works best once Skelf is in
> `/Applications`.

After the first launch, Skelf keeps itself current automatically. Run a check on demand from
**Check for Updates…** (the app menu or the popover's ⋯), or turn the automatic check off in
**Settings ▸ Updates**.

Prefer to build it yourself? See [Build & run](#build--run).

## Build & run

```bash
open Package.swift              # open in Xcode and Run, or:
swift build                     # SwiftPM build
./build.sh && open Skelf.app    # bundled, ad-hoc-signed Skelf.app (icon + Info.plist)
./scripts/make-dmg.sh           # a "drag to Applications" Skelf.dmg for sharing
```

> [!NOTE]
> Building needs **Xcode 26+** for the macOS 26 SDK and SwiftUI's macro plugin. `build.sh`
> produces the real `.app` and locates that macro plugin for plain `swiftc`; `swift build` and
> Xcode find it automatically.

## Settings

Open with **⌘,**, the ⚙ toolbar button, or the popover's ⋯ menu. Native macOS preferences with
four tabs, persisted to `UserDefaults`:

| Tab | Controls |
|------|----------|
| **General** | Launch at Login · Menu Bar Only · Global Shortcut (⌥⌘S) · Play Sounds |
| **Appearance** | Theme (System / Light / Dark) · Show Art Covers · Refresh Art · Reduce Motion |
| **Intelligence** | On-Device AI Search |
| **Updates** | Automatically Check for Updates · Check Now |

The full macOS menu bar is wired up too — **File ▸ New Folder (⌘N)** and **Refresh Skills
(⌘R)**, Edit, Window, and Help. In **Menu Bar Only** mode, ⌘Q tucks Skelf back into the menu
bar; **Quit Completely (⌥⌘Q)** always exits and removes the icon.

## Where it reads from

Skelf detects skills wherever Claude Code keeps them — no configuration needed. On launch (and
live, as things change) it scans:

| Location | What it finds |
|----------|---------------|
| **Installer layout** — `<base>/.agents/skills/<id>/SKILL.md` | name, description, version, body. A symlink in `<base>/.claude/skills/<id>` marks each **enabled** skill; `<base>/skills-lock.json` adds source repo + category. Checked at `~/Dev`, your home folder, and the launched project. |
| **Claude config dir** — `<config>/skills/` and `<config>/plugins/**/skills/` | standalone and **plugin/marketplace** skills, at every base it can find: `$CLAUDE_CONFIG_DIR`, `~/.claude`, `$XDG_CONFIG_HOME/claude`, `~/.config/claude`. |
| **Project skills** — a bounded scan of `~/Dev`, `~/Developer`, `~/Projects`, `~/code`, … | any repo with a `.claude/skills` or `.agents/skills` directory. |

Skills in a plain `skills/` or plugin directory are always enabled; only the installer layout
tracks enabled/disabled (via the `.claude/skills` symlink). Override the installer base dir with
`SKILLS_DEV_DIR=…`.

Avatars and artwork cache under `~/Library/Caches/dev.fulltime.skelf/`; folders, favorites, and
settings persist in `UserDefaults` (`dev.fulltime.skelf`).

## CLI modes (no GUI)

```bash
./Skelf.app/Contents/MacOS/Skelf --version          # print the version and exit
./Skelf.app/Contents/MacOS/Skelf --list             # print all skills + state
./Skelf.app/Contents/MacOS/Skelf --copy <skill-id>  # put /<skill-id> on the clipboard
open Skelf.app --args --open <skill-id>             # launch into a skill's detail
open Skelf.app --args --enter <folder>              # launch into a folder
open Skelf.app --args --popover                     # launch with the popover open
```

## Privacy

> [!NOTE]
> Skelf reads your skills from disk and reaches the network over HTTPS only for **NASA imagery**
> (`images.nasa.gov`), **creator avatars** (`github.com`), and **update checks** (`api.github.com`
> plus the release download host). It sends only a skill keyword and standard request headers —
> no account, no analytics, no telemetry. Turn network art off with **Settings ▸ Show Art
> Covers**, and the update check with **Settings ▸ Automatically Check for Updates**.

## Project layout

```
Package.swift               # SwiftPM target (opens in Xcode · swift build)
Sources/Skelf/
  ├── *.swift               # the app, split by concern (Skills, Art, Cards, Detail,
  │                         #   Grid, Markdown, Navigation, MenuBar, Updater, App, …)
  └── Resources/            # runtime assets: art-map.json · skelf.svg · skelf-menubar.pdf
Resources/                  # app-packaging assets: Skelf.icns · AppIcon/
build.sh                    # swiftc → Skelf.app (git-ignored build artifact)
```

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the per-file breakdown.

## Credits

Made by **FullTime Studio** ([@devbyshima](https://github.com/devbyshima)). Card art is
public-domain imagery courtesy of [NASA](https://images.nasa.gov/) — Skelf isn't affiliated with
or endorsed by NASA.
