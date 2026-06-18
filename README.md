# Skelf

A tiny **native macOS menu-bar + window app** that lists your installed Claude Code
skills. Browse a **grid** of skills, click one to open its **detail screen**, and hit
**Copy** to put its slash-command initiator (e.g. `/humanizer`) on the clipboard so
you can paste it into cloud sessions.

Single Swift file. The **window navigation and toolbars are SwiftUI** (a
`NavigationStack` with a Liquid Glass `.toolbar`, bridged into the AppKit window via
`NSHostingController.sceneBridgingOptions`), hosting an **AppKit grid + detail**. It
compiles with `swiftc` from the Command Line Tools, **plus** Xcode's SwiftUI macro
plugin (`libSwiftUIMacros.dylib`) for `@State`/`@Bindable` — `build.sh` locates it
automatically and passes `-plugin-path`. Targets **macOS 26** and adopts **Liquid
Glass** (with the macOS 27 interactive bounce where available).

## Build & run

```bash
./build.sh           # compiles Skelf.app with swiftc (+ Xcode's SwiftUI macro plugin)
open Skelf.app        # launch (dock icon + window + menu-bar icon)
```

> `build.sh` needs Xcode (or Xcode-beta) installed for the SwiftUI macro plugin; it
> falls back with a warning if absent. Everything else is plain `swiftc`.

## What it does

- **Favorites** — favoriting lives in the skill's **⋯ menu** (Favorite / Unfavorite),
  in the **detail screen** (hero star + a toolbar star), or on a popover row. Favorited
  tiles keep a subtle **★ prefix** and sort **first** in both the grid and the popover,
  so your most-used skills are always one click away. Pins persist across launches
  (stored in `UserDefaults`, key `favoriteSkillIDs`).
- **Folders** (display-only — never touches Claude's config) — organize skills into
  nested folders. The window navigates folder-by-folder with a **SwiftUI
  `NavigationStack`** (tap a folder to push into it, the toolbar **back chevron** to go
  up); a **New Folder** toolbar button creates them. Every tile has a **⋯ menu**:
  skills offer Open / Copy Slash Command / **Favorite** / **Move to Folder…** / **Copy
  to Folder…** / Cut / Copy / Remove; folders offer Open / Rename / New Folder Inside /
  Cut / Delete. **Move to Folder / Copy to Folder** pick a destination straight from a
  folder-tree submenu. You can also Cut or Copy a skill, navigate into a folder, then
  hit **Paste** (toolbar button) — copy stays on the clipboard so you can paste into
  several folders. The tree is persisted in `UserDefaults` (`folderTreeV1`).
- **Drag & drop / reorder** — a **click opens** a tile, while a **press-and-drag** moves
  it (a `GridCollectionView` tells the two apart, so reorder/move is no longer pre-empted
  by navigation). Drag a tile **onto a folder** to move it in; drag between tiles to
  **reorder** within the current folder (order persists); and in the **menu-bar
  popover**, drag a favorite **onto a folder row** to file it without opening the window.
  (`NSCollectionView` dragging delegate + `NSDraggingSource`/`NSDraggingDestination`;
  grid dragging enabled when not searching/filtering.)
- **Undo / redo** — every organization change (move, copy, reorder, rename, create,
  delete) is undoable with **⌘Z / ⌘⇧Z** or the **Edit** menu (the whole folder tree is
  snapshotted per change via `UndoManager`). The app now ships a proper main menu too.
  Since the menu-bar popover has no menu of its own, dropping a skill into a folder there
  shows a brief **undo toast** — a *detached* Liquid Glass panel that **drops in below
  the popover with a bounce** (its own `NSPanel`), and dismisses with the popover (it's
  tied to the menu's lifecycle via `NSPopoverDelegate`).
- **Grid** — the current folder's contents: sub-folder tiles + skill tiles (gradient
  monogram, name, `/initiator`). Disabled skills are dimmed. Tiles **lift on hover** and
  **squash-and-stretch on press** (`CASpringAnimation`); opening a skill **pushes** its
  detail with SwiftUI's native navigation transition. Search + All / Enabled / Off
  filter live in the **toolbar**. The window bottom is clean (no status footer).
- **Detail screen** — opens as a **NavigationStack push**. Laid out as a **bento**: a
  hero block (big gradient monogram, name, a `/initiator` chip, an Enabled/Off badge,
  and favorite + add-to-folder icons), one prominent **Copy `/name`** action as an
  **interactive Liquid Glass pill** (`NSGlassEffectView` with `effectIsInteractive` — it
  bounces on click), a **2-column grid of meta cards** (Version / Category / Files /
  Installed, plus full-width Source / Path), a readable description, and **Reveal
  SKILL.md / View on GitHub** links. The toolbar carries a **back chevron**, **Copy**,
  and a **Favorite** toggle. Typography uses semantic `NSFont` text styles.
- **Menu-bar popover** — Passwords-style with **Liquid Glass** containers (corners
  **concentric** with the popover via `cornerConfiguration`, macOS 27), and
  **auto-sizes** to its content. The status-bar icon is the **Skelf mark** (loaded from
  `Icons/skelf.svg` as a vector template). The top shows two grouped glass cards:
  **Favorites** (copy icon → copies `/name`) and **Folders** (`>` chevron → navigates
  **into** the folder, with a back button and a **springy slide** between views).
  **Search** reaches every skill. Top-right has a **window icon** (opens the app) and a
  **⋯ options menu** (Open Window / Refresh / **Play Sounds** / About / Quit).
- **UI sounds** (off by default) — a tasteful system sound on copy (`Tink`) and on a
  move/drop (`Pop`). Toggle them from the popover's **⋯ → Play Sounds** menu (checkmark
  shows the state; flipping it on plays a quick preview). Persisted in `UserDefaults`
  (`soundEnabled`).
- **Auto-detect** — an FSEvents watcher on the skill directories means adding,
  removing, enabling, disabling, or editing a skill updates the app **live**, no manual
  refresh.

## Where it reads from

Live from disk, every launch / change — nothing is cached or persisted:

| Path | Used for |
|------|----------|
| `~/Dev/.agents/skills/<id>/SKILL.md` | name, description, version (frontmatter) |
| `~/Dev/.claude/skills/<id>` | symlink present ⇒ **enabled** (else installed-but-off) |
| `~/Dev/skills-lock.json` | source repo + category (from `skillPath`) |

Override the base dir with `SKILLS_DEV_DIR=/some/path open Skelf.app`.

Current inventory: **47 skills — 43 enabled, 4 off** (`caveman`, `diagnose`,
`write-a-skill`, `zoom-out`).

## CLI modes (no GUI)

```bash
./Skelf.app/Contents/MacOS/Skelf --list            # print all skills + state
./Skelf.app/Contents/MacOS/Skelf --copy humanizer  # put /humanizer on the clipboard
open Skelf.app --args --open humanizer             # launch straight into a skill's detail
open Skelf.app --args --popover                    # launch with the menu-bar popover open
SKILLSHELF_DEBUG=1 ./Skelf.app/Contents/MacOS/Skelf 2>log   # log reloads to stderr
```

## Files

- `Skelf.swift` — the whole app (model + disk store + FSEvents watcher + SwiftUI
  navigation shell + AppKit grid + detail + menu-bar popover + glass toast). Single file.
- `build.sh` — compiles the `.app` bundle (finds Xcode's SwiftUI macro plugin), embeds
  the icon, and ad-hoc signs it.
- `Skelf.icns` — app/dock icon (generated from `Icons/Skelf-iOS-Default-1024@1x.png`).
- `Icons/` — the full branding set: app-icon variants (iOS/watchOS · Default / Dark /
  Clear / Tinted, all sizes) and the source `skelf.svg` mark used for the menu-bar icon.

## Notes / possible next steps

- Not code-signed for distribution (ad-hoc only) — fine for personal local use.
- For a menu-bar-only app (no dock icon), set `LSUIElement` in `Info.plist` and switch
  the activation policy to `.accessory`.
- Toggling enabled/off is read-only; making it create/remove the `.claude/skills`
  symlink would be the natural next feature.
