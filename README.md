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

- **Grid of cards** — each skill is a **portrait card** whose background is the
  **creator's GitHub avatar** (fetched from `https://github.com/<owner>.png`, **no token
  needed**, then disk-cached); skills with no `owner/repo` source fall back to a
  generated gradient. A card shows the name, a category tag pill (red **off** when
  disabled), the description, and a white **Copy** button, with **Liquid Glass** favorite
  ★ and ⋯ controls top-right. Cards **fill each row evenly** at any window width, **scale
  on hover** (whole card, with a soft shadow), and **squash on press**. Opening a skill
  is a SwiftUI **NavigationStack push**.
- **Auto-organized by creator** — skills group into a folder per creator automatically,
  but only when it's meaningful: the source must be a real `owner/repo` **and** that
  owner must have **≥ 2** installed skills. Singletons, `local`, and sourceless skills
  stay loose at root (a lone skill doesn't earn a folder), and folders that stop being
  valid dissolve. Folders you make and skills you file yourself are never touched.
- **Favorites** — toggle from a card's **★**, the skill's **⋯ menu**, or the detail
  screen. Favorites sort **first** in the grid and the popover. Persisted in
  `UserDefaults` (`favoriteSkillIDs`).
- **Folders** (display-only — never touches Claude's config) — the window navigates
  folder-by-folder with a **SwiftUI `NavigationStack`** (tap a folder to push in, the
  toolbar **back chevron** to go up); a **New Folder** toolbar button creates them. Every
  tile has a **⋯ menu**: skills offer Open / Copy Slash Command / **Favorite** / **Move
  to Folder…** / **Copy to Folder…** / Cut / Copy / Remove; folders offer Open / Rename /
  New Folder Inside / **Add to Menu Bar** / Cut / Delete. Cut or Copy a skill, navigate
  into a folder, then hit **Paste** (toolbar button). The tree is persisted in
  `UserDefaults` (`folderTreeV1`).
- **Drag & drop / reorder** — a **click opens** a tile, while a **press-and-drag** moves
  it (a `GridCollectionView` tells the two apart with a 4px threshold, so reorder/move is
  not pre-empted by navigation). Drag a tile **onto a folder** to move it in; drag between
  tiles to **reorder** (order persists); and in the **menu-bar popover**, drag a favorite
  **onto a folder row** to file it. (Grid dragging is enabled when not searching.)
- **Undo / redo** — every organization change is undoable with **⌘Z / ⌘⇧Z** or the
  **Edit** menu (the whole folder tree is snapshotted per change via `UndoManager`). In
  the popover, a drop shows a brief **undo toast** — a detached Liquid Glass `NSPanel`
  that **drops in below the popover with a bounce** and dismisses with the menu.
- **Detail screen** — opens as a NavigationStack push, in **two columns** under an
  **image header banner** (the creator avatar + name + status + `/initiator`). The
  **scrollable left** column is the read-only **SKILL.md**: a **Summary** at the top
  (the description) followed by the full markdown **rendered GitHub-style** (headings,
  **bold**/*italic*/`code`, links, lists, blockquotes, fenced code). The **sticky right
  sidebar** has **Source** (creator avatar + repo + View on GitHub), **Slash command**
  (Copy), **Details** (status / version / category / files / installed), and **Actions**
  (Favorite / Add to Folder / Reveal). The toolbar carries a **back chevron**, **Copy**,
  and a **Favorite** toggle.
- **Menu-bar popover** — Passwords-style with **Liquid Glass** cards that **auto-size**
  to content. The status-bar icon is the **Skelf mark** (`Resources/skelf.svg`, a vector
  template). It shows **Favorites** (copy icon → copies `/name`, with a **"Copied /name"
  toast**) and the **Folders you've added to the menu bar** (folders are hidden until you
  pick **⋯ → Add to Menu Bar**; chevron rows drill in). **Search** reaches every skill.
  Top-right has a **window icon** (opens the app) and a **⋯ options menu** (Open Window /
  Refresh / **Play Sounds** / About / Quit).
- **UI sounds** (off by default) — a tasteful system sound on copy (`Tink`) and on a
  move/drop (`Pop`). Toggle from the popover's **⋯ → Play Sounds**. Persisted in
  `UserDefaults` (`soundEnabled`).
- **Auto-detect** — an FSEvents watcher on the skill directories updates the app **live**
  when a skill is added, removed, enabled, disabled, or edited — no manual refresh.

## Where it reads from

Skill data is read live from disk every launch / change (only creator avatars are
cached — see below):

| Path | Used for |
|------|----------|
| `~/Dev/.agents/skills/<id>/SKILL.md` | name, description, version, full body |
| `~/Dev/.claude/skills/<id>` | symlink present ⇒ **enabled** (else installed-but-off) |
| `~/Dev/skills-lock.json` | source repo + category (from `skillPath`) |

Override the base dir with `SKILLS_DEV_DIR=/some/path open Skelf.app`.

Creator avatars are fetched once from GitHub and cached at
`~/Library/Caches/dev.fulltime.skelf/avatars/`; the folder overlay, favorites, and the
sounds toggle persist in `UserDefaults` (`dev.fulltime.skelf`).

## CLI modes (no GUI)

```bash
./Skelf.app/Contents/MacOS/Skelf --list            # print all skills + state
./Skelf.app/Contents/MacOS/Skelf --copy humanizer  # put /humanizer on the clipboard
open Skelf.app --args --open humanizer             # launch straight into a skill's detail
open Skelf.app --args --popover                    # launch with the menu-bar popover open
SKILLSHELF_DEBUG=1 ./Skelf.app/Contents/MacOS/Skelf 2>log   # log reloads to stderr
```

## Project layout

```
Skelf/
├── Sources/Skelf/Skelf.swift   # the whole app, one file
├── Resources/
│   ├── skelf.svg               # menu-bar mark (vector template)
│   ├── Skelf.icns              # app/dock icon
│   └── AppIcon/                # full branding set (iOS/watchOS · Default/Dark/Clear/Tinted)
├── build.sh                    # swiftc → Skelf.app (no Xcode project)
├── LICENSE                     # MIT
└── README.md
```

- `Sources/Skelf/Skelf.swift` — model + disk store + FSEvents watcher + SwiftUI
  navigation shell + AppKit grid + detail + menu-bar popover + glass toast, in one file.
- `build.sh` — compiles the `.app` bundle (finds Xcode's SwiftUI macro plugin), embeds
  `Resources/Skelf.icns` + `Resources/skelf.svg`, and ad-hoc signs it. `Skelf.app/` is a
  build artifact (git-ignored).

## Notes / possible next steps

- Not code-signed for distribution (ad-hoc only) — fine for personal local use.
- For a menu-bar-only app (no dock icon), set `LSUIElement` in `Info.plist` and switch
  the activation policy to `.accessory`.
- Toggling enabled/off is read-only; making it create/remove the `.claude/skills`
  symlink would be the natural next feature.
