# Releasing Skelf

How a change gets from a branch to someone's Mac: the branching model, the three release
channels, and the exact commands for cutting a release, running a beta, promoting to production,
and shipping a hotfix.

Skelf is a versioned desktop app distributed as a DMG on GitHub Releases, with a built-in
updater. That shapes everything below: users sit on a *version*, not on whatever is deployed, so
old versions have to stay fixable.

---

## 1. The model at a glance

```
main  ──●──●──●──●──●──●──●──▶            trunk, all new features, channel: dev
         ╲              ╲
          ╲              ╲ cut release/1.7 ──●──●──▶   channel: beta
           ╲                                  │
            ╲                                 └─ tag v1.7.0 ─▶ channel: production
             ╲
              cut release/1.6 ──●──●──●──▶    older series, still patchable
                                 │  │
                                 │  └─ tag v1.6.2  (hotfix) ─┐
                                 └─ tag v1.6.1              │ merge forward into
                                                            └▶ release/1.7, then main
```

| Branch | Rule |
|---|---|
| `main` | Trunk. Every feature lands here first, via PR. Never tagged for production in the branch flow. |
| `release/X.Y` | Cut from main when X.Y is feature-complete. **Bug fixes only — no new features, ever.** Lives as long as anyone runs X.Y. |
| anything else | Short-lived work branches, PR'd into `main` (features) or into a `release/X.Y` (fixes). |

### The three channels

| Channel | Source | Tag | Who gets it |
|---|---|---|---|
| **production** | `release/X.Y`, promoted | `vX.Y.Z` | Everyone. Shown as "Latest release". |
| **beta** | `release/X.Y`, every push | `vX.Y.Z-beta.N` | Users who ticked Settings ▸ Updates ▸ *Include Beta Releases*. Published as a GitHub pre-release. |
| **dev** | `main` | none | Contributors building locally. Not published. |

The channel is stamped into the built bundle (`SKELFReleaseChannel` in `Info.plist`, via
`SKELF_CHANNEL` in `build.sh`) and shown in Settings ▸ Updates.

### Versioning

[Semantic Versioning](https://semver.org/spec/v2.0.0.html): `MAJOR.MINOR.PATCH`.

- **MAJOR** — a change that breaks how people already use Skelf: dropping a macOS version,
  removing a feature or setting, changing where skills are read from, a license change that
  affects redistribution.
- **MINOR** — new features and visible improvements, backward compatible.
- **PATCH** — bug fixes only. What goes out on a hotfix.

Pre-releases are `vX.Y.Z-beta.N` and sort *below* the final `vX.Y.Z`, so a beta tester is
automatically moved onto the stable build when it ships.

**The version lives in exactly one place**: `SKELF_VERSION` in [`build.sh`](build.sh). Tags,
`Info.plist`, `Skelf --version`, and the updater all derive from it. Never edit it by hand on
`main` — the workflows do it.

---

## 2. Cut a release branch (opens the beta)

Do this when `main` is feature-complete for the next version.

**The easy way** — Actions ▸ **Cut Release Branch** ▸ Run workflow ▸ `minor` (or `major`). It
branches `release/X.Y`, stamps `X.Y.0` into `build.sh` on the branch, pushes it, and kicks off
`beta.yml` to publish `vX.Y.0-beta.1`. Nothing on `main` changes — main is already the *next*
version's trunk.

(It has to *ask* for that first beta run: a push made with `GITHUB_TOKEN` doesn't fire
push-triggered workflows, so the branch appearing wouldn't start `beta.yml` by itself. Pushes you
make yourself do, which is why §3 needs no such step.)

**By hand**, if you'd rather:

```bash
git switch main && git pull
git switch -c release/1.6
sed -i '' -E 's/^SKELF_VERSION="[0-9.]+"/SKELF_VERSION="1.6.0"/' build.sh
sed -i '' -E 's/^SKELF_BUILD="[0-9]+"/SKELF_BUILD="11"/' build.sh
git commit -am "Stabilize 1.6.0 on release/1.6"
git push -u origin release/1.6
```

From this moment: **features go to `main`, fixes go to `release/1.6`.** If you catch yourself
adding a feature to a release branch, it belongs on main and in the next minor.

## 3. Run a beta

Every push to `release/X.Y` publishes the next beta automatically — there's nothing to run.

Fixing a bug found in beta:

```bash
git switch release/1.6 && git pull
git switch -c fix/popover-width
# …fix, and add a note under "## [Unreleased]" in CHANGELOG.md…
git commit -am "Keep the popover a constant width"
git push -u origin fix/popover-width
gh pr create --base release/1.6 --title "Keep the popover a constant width"
```

Merging that PR publishes `v1.6.0-beta.2`. CI (build + SwiftLint) runs on the PR.

**Every fix that lands on a release branch must also reach `main`** — see §6.

## 4. Promote to production

When the beta is quiet, promote the branch by tagging it. The tag is the release trigger.

```bash
git switch release/1.6 && git pull

# Move the beta's notes out of "Unreleased" into a real section, on the branch.
#   ## [1.6.0] - 2026-08-13
$EDITOR CHANGELOG.md
git commit -am "Changelog for 1.6.0"
git push

git tag -a v1.6.0 -m "Skelf 1.6.0"
git push origin v1.6.0
```

`release.yml` builds the tagged commit, packages `Skelf.dmg` + `SHA256SUMS`, and publishes the
GitHub Release with that CHANGELOG section as its notes. It becomes "Latest release", so every
user — beta or not — is offered it.

Then merge the branch's changelog and fixes back to main:

```bash
git switch main && git pull
git merge --no-ff release/1.6      # see §6 on the build.sh conflict
git push
```

## 5. Ship a hotfix

**Fix it on the oldest release branch that still has the bug.** Fixing it only on the newest one
strands everyone who hasn't upgraded; fixing it on main only means it ships whenever the next
minor does.

Say the bug exists in 1.5 and 1.6, and 1.6 is current:

```bash
git switch release/1.5 && git pull
git switch -c fix/menubar-icon

# …fix it. Keep the diff as small as it can be — this branch ships to production directly.
$EDITOR Sources/Skelf/App.swift
$EDITOR CHANGELOG.md               # note it under "## [Unreleased]"
git commit -am "Fix the menu-bar icon rendering blank"
git push -u origin fix/menubar-icon
gh pr create --base release/1.5 --title "Fix the menu-bar icon rendering blank"
```

Once merged (which publishes a beta of the patch), bump and tag the patch on that branch:

```bash
git switch release/1.5 && git pull
sed -i '' -E 's/^SKELF_VERSION="[0-9.]+"/SKELF_VERSION="1.5.4"/' build.sh
sed -i '' -E 's/^SKELF_BUILD="[0-9]+"/SKELF_BUILD="12"/' build.sh
$EDITOR CHANGELOG.md               # promote Unreleased → "## [1.5.4] - <date>"
git commit -am "Release 1.5.4"
git push
git tag -a v1.5.4 -m "Skelf 1.5.4"
git push origin v1.5.4
```

Then propagate — §6, immediately, not later.

## 6. Propagate a fix forward

A fix that lands on an old release branch and stays there comes back as a regression the moment
someone upgrades. **Forward-port on the same day you ship it**, oldest branch to newest, ending at
`main`:

```bash
# release/1.5 → release/1.6
git switch release/1.6 && git pull
git merge --no-ff release/1.5
# …resolve conflicts, run ./build.sh, push…
git push

# release/1.6 → main
git switch main && git pull
git merge --no-ff release/1.6
git push
```

**The `build.sh` conflict is expected**, because both sides changed `SKELF_VERSION`. The rule:
**keep the higher version — the target branch's own.** Merging `release/1.5` (1.5.4) into
`release/1.6` (1.6.0) keeps `1.6.0`. Same for `SKELF_BUILD`. Getting this backwards silently
un-releases a version, so check it every time:

```bash
git checkout --ours build.sh          # during the merge, on the newer branch
grep -E '^SKELF_(VERSION|BUILD)=' build.sh
git add build.sh
```

If the branches have diverged too far to merge cleanly, cherry-pick the fix commit instead — the
goal is that the fix exists everywhere, not that the history is uniform:

```bash
git switch main && git pull
git cherry-pick -x <sha>              # -x records where it came from
git push
```

**Checklist for any hotfix — none of it is optional:**

- [ ] Fixed on the oldest affected `release/X.Y`
- [ ] Tagged `vX.Y.Z` there and published
- [ ] Merged (or cherry-picked) into every newer `release/*`
- [ ] Merged (or cherry-picked) into `main`
- [ ] `build.sh` version is still the highest one on each branch it touched
- [ ] `CHANGELOG.md` mentions it under the patch version

## 7. Retiring a release branch

Keep `release/X.Y` while anyone might still be running X.Y. When the updater has moved everyone
off it, stop merging into it and leave the branch in place — the tags are the historical record
and the branch costs nothing.

---

## Feature flags

Because features land on `main` continuously but a release branch snapshots it, an unfinished
feature would otherwise block cutting a release. Flags are the escape hatch: land it dark.

Declare the flag in [`Sources/Skelf/FeatureFlags.swift`](Sources/Skelf/FeatureFlags.swift):

```swift
static let all: [FeatureFlag] = [
    FeatureFlag(name: "skillGraph",
                title: "Skill Graph",
                summary: "Force-directed view of how skills reference each other.",
                enabledIn: [.dev, .beta]),
]
```

Gate the code with it:

```swift
if FeatureFlags.isOn("skillGraph") { SkillGraphView(model: model) }
```

- On by default in the channels listed in `enabledIn` — so `[.dev]` means it's live for
  contributors and invisible to everyone else.
- Any user can override it: `defaults write dev.fulltime.skelf flag.skillGraph -bool YES`, or
  `defaults delete …` to go back to the channel default.
- Dev and beta builds list every declared flag in Settings ▸ Updates with a checkbox. Production
  builds show nothing.
- **Flags are temporary.** When the feature ships, delete the `FeatureFlag` entry *and* the
  `if FeatureFlags.isOn(…)` branches in the same PR. A flag left behind becomes a second, untested
  code path. `FeatureFlags.all` being empty is the healthy state.

---

## Local builds

```bash
./build.sh                                                   # production stamp, version from build.sh
SKELF_VERSION_OVERRIDE=1.6.0-beta.9 SKELF_CHANNEL=beta ./build.sh   # what CI does for a beta
```

`swift build` produces no `Info.plist`, so it reports version `dev` and channel `dev`, and
auto-update is disabled — intentional.

## The workflows

| Workflow | Trigger | Does |
|---|---|---|
| [`ci.yml`](.github/workflows/ci.yml) | push/PR on `main` and `release/**` | `swift build` + SwiftLint |
| [`cut-release-branch.yml`](.github/workflows/cut-release-branch.yml) | manual | Cuts `release/X.Y` from main |
| [`beta.yml`](.github/workflows/beta.yml) | push to `release/**` | Builds + publishes `vX.Y.Z-beta.N` as a pre-release |
| [`release.yml`](.github/workflows/release.yml) | `v*.*.*` tag, or push to main | Builds + publishes the production release |
| [`cut-release.yml`](.github/workflows/cut-release.yml) | manual | Older path: releases straight off main, no beta. Fine for a quick patch when no release branch is open. |

## Known limitations

- **Builds are unsigned** (ad-hoc, no Developer ID, not notarized), so a downloaded DMG needs the
  System Settings ▸ Privacy & Security approval dance. This is the single biggest thing standing
  between Skelf and a clean install; see [`docs/RELEASE_READINESS.md`](docs/RELEASE_READINESS.md).
- `scripts/make-dmg.sh` lays out the DMG window with Finder/AppleScript, which can be flaky on a
  headless runner. If a release build fails there, build the DMG locally and upload it by hand.
- The updater only sees releases that carry a `Skelf.dmg` asset, so a release published without
  one is invisible to existing installs.
