# Skelf

A tiny **native macOS menu-bar + window app** that lists your installed Claude Code skills.
Browse a grid, open a skill's detail, and **Copy** its slash-command (e.g. `/humanizer`) to
paste into cloud sessions.

One Swift file: SwiftUI `NavigationStack` + Liquid Glass toolbars (bridged via
`NSHostingController.sceneBridgingOptions`) hosting an AppKit grid + detail. Targets
**macOS 26** (Liquid Glass). Compiles with `swiftc` plus Xcode's SwiftUI macro plugin.

## Build & run

```bash
./build.sh      # compiles Skelf.app (swiftc + Xcode's SwiftUI macro plugin)
open Skelf.app  # launch
```

> Needs Xcode (or Xcode-beta) for the SwiftUI macro plugin; otherwise plain `swiftc`.

## Features

- **Grid of cards** — each skill is a portrait card backed by a **unique public-domain
  painting** (Art Institute of Chicago, bundled `art-map.json`, disk-cached), with a
  generated gradient+icon fallback when offline or unmapped. Cards reflow to any width,
  scale on hover, squash on press; a click opens the detail.
- **Auto-organized by creator** — skills group into a folder per `owner` automatically when
  that owner has ≥ 2 installed skills; singletons stay loose. Folder tiles show the
  creator's GitHub avatar. Make your own folders too (display-only — never touches Claude's
  config).
- **Favorites** — toggle from a card's ★, a ⋯ menu, or the detail; a pinned **Favorites
  folder** gathers them all.
- **Detail screen** — two columns under a painting banner: scrollable **SKILL.md** (rendered
  GitHub-style) + a sticky sidebar (Source / Slash command / Details / Actions). Click the
  banner for a **centered painting panel** (artwork + history + why it was chosen).
- **Global search** — spans **every folder and skill** (name / description / category /
  creator), **identical in the window and the menu bar**.
- **Menu-bar popover** — Liquid Glass cards for Favorites + menu-bar folders; copies `/name`
  with a toast. Toggle from anywhere with **⌥⌘S**.
- **Settings** (**⌘,** / popover ⋯ / ⚙ toolbar button) — Launch at Login, Menu Bar Only,
  Global Shortcut, Appearance (System/Light/Dark), Show Painting Covers, Refresh Painting
  Art, Reduce Motion, Play Sounds. Opens centered; persists to `UserDefaults`.
- **Menus** — Skelf / File (New Folder ⌘N, Refresh Skills ⌘R) / Edit (Undo ⌘Z, Redo ⌘⇧Z) /
  Window / Help.
- **Auto-detect** — an FSEvents watcher updates the app live as skills are added, removed,
  enabled, disabled, or edited.

## Where it reads from

Skill data is read live from disk (override the base dir with `SKILLS_DEV_DIR=…`):

| Path | Used for |
|------|----------|
| `~/Dev/.agents/skills/<id>/SKILL.md` | name, description, version, body |
| `~/Dev/.claude/skills/<id>` | symlink present ⇒ enabled |
| `~/Dev/skills-lock.json` | source repo + category |

Avatars and paintings cache under `~/Library/Caches/dev.fulltime.skelf/`; folders, favorites,
and settings persist in `UserDefaults` (`dev.fulltime.skelf`).

## CLI modes (no GUI)

```bash
./Skelf.app/Contents/MacOS/Skelf --list            # print all skills + state
./Skelf.app/Contents/MacOS/Skelf --copy humanizer  # put /humanizer on the clipboard
open Skelf.app --args --open humanizer             # launch into a skill's detail
open Skelf.app --args --popover                    # launch with the popover open
```

## Layout

```
Sources/Skelf/Skelf.swift   # the whole app, one file
Resources/                  # skelf.svg · Skelf.icns · art-map.json · AppIcon/
build.sh                    # swiftc → Skelf.app (git-ignored build artifact)
```

Ad-hoc signed (personal local use). Launch at Login registers reliably only for a signed app
in `/Applications`.
