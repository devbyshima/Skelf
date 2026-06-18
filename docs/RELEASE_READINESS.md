# Skelf 1.0.0 — Release-Readiness Report

> Generated 2026-06-19 by a multi-agent audit (6 audit dimensions with real builds + 4
> adversarially-verified deep-research tracks). This is an analysis artifact — delete it
> once the actions below are done.

## 1. Verdict

**Not ready to ship publicly today.** The single biggest blocker: **the app is ad-hoc signed and un-notarized** (`build.sh:73` → `codesign --force --deep --sign -`), and there is no Apple Developer ID identity on the machine (`security find-identity -v -p codesigning` → 0 valid identities). A DMG downloaded from GitHub will be Gatekeeper-blocked on macOS 15/26 with no easy bypass, which kills the download funnel before a user ever sees the app.

The code itself is healthy — `swift build` compiles clean, both build paths run `--list` identically, security/privacy posture is clean, and no crash-on-launch risk was found. The blockers are all in **release engineering and distribution**, not the product.

---

## 2. Release blockers (must fix before public release)

### B1 — No trusted signature / notarization (HEADLINE BLOCKER)

**Problem.** `build.sh:73` ad-hoc signs (`--sign -`, no Team ID, no hardened runtime, no entitlements, deprecated `--deep`). `scripts/make-dmg.sh` produces an **unsigned** DMG with no notarization ticket. Verified: `spctl -a -t exec Skelf.app` → rejected; `spctl -a -t open Skelf.dmg` → rejected ("no usable signature"); `stapler validate Skelf.dmg` → "does not have a ticket stapled."

**Why it blocks.** On macOS 15 Sequoia and 26 Tahoe (Skelf's `LSMinimumSystemVersion` is 26.0, so these rules are fully in force), a quarantined download from an un-notarized app is hard-blocked. **Apple removed the right-click → Open bypass in Sequoia.** The only path left is System Settings → Privacy & Security → "Open Anyway" + admin auth + a second scary dialog — a flow most users read as malware and abandon. A valid Developer ID signature *alone* is not enough; **notarization is the load-bearing step** (a signed-but-un-notarized app hits the same wall).

**The correct minimal path to a clean download (post-verification):**

1. **Enroll in the Apple Developer Program ($99/yr)** — the hard prerequisite. There is no free notarization path; a "Developer ID Application" certificate is only issued to paid accounts (valid 5 years).
2. From the Developer portal, create a **Developer ID Application** certificate (not "Apple Development", not "Mac App Distribution") into the login keychain.
3. **Sign inside-out, never `--deep`.** Skelf is a single Mach-O today (no nested frameworks), so this is one command on the bundle:
   ```sh
   codesign --force --options runtime --timestamp \
     --sign "Developer ID Application: <Name> (<TEAMID>)" Skelf.app
   ```
   `--options runtime` (hardened runtime) and `--timestamp` are both **required** or notarization is rejected. **Keep Skelf unsandboxed** — do **not** add `com.apple.security.network.client`; that entitlement only does anything under App Sandbox. An unsandboxed Developer-ID app ships with an empty/minimal entitlements set and has unrestricted outbound networking.
4. **Build the DMG, then sign the DMG** with the same Developer ID Application identity (signing the DMG also exempts the app from App Translocation).
5. **Notarize** with an App Store Connect API key (recommended over app-specific password):
   ```sh
   xcrun notarytool store-credentials "skelf-notary" \
     --key AuthKey_XXXX.p8 --key-id <KEYID> --issuer <ISSUER_UUID>
   xcrun notarytool submit Skelf.dmg --keychain-profile "skelf-notary" --wait
   ```
   Note: `notarytool` can return success-but-rejected — check the verdict and `xcrun notarytool log <id>` on failure. For an **Individual** (non-Team) API key, omit `--issuer` or you get a 401.
6. **Staple** the DMG (and ideally the `.app` before packaging, so the ticket travels if a user copies it out):
   ```sh
   xcrun stapler staple Skelf.dmg
   xcrun stapler validate Skelf.dmg
   spctl -a -vv -t open Skelf.dmg          # must say "accepted, source=Notarized Developer ID"
   ```
7. **Test the real download path**: serve over HTTPS, download via Safari (which sets `com.apple.quarantine`), and confirm it opens with no security block. Local builds skip Gatekeeper, so testing the locally built `.app` gives a false "it works."

*(Correction applied vs. research: do not claim notarization makes Tahoe launch "noticeably faster" — Tahoe does skip first-run XProtect scans for notarized apps, but the cited source found no meaningful launch-time gain. Notarize for the trust/UX-warning benefit, not for speed. Also do not assert "Tahoe tightened notarization checks" — unsupported.)*

**Cheaper fallback if you ship 1.0 unsigned.** Acceptable only if you document it loudly. Do **not** teach `xattr -dr com.apple.quarantine` as the headline workaround for a tool that reads the user's skills directory. Instead, the README must state plainly that release builds are un-notarized and give the exact macOS 15/26 flow:

> On first launch macOS will block Skelf. Open **System Settings → Privacy & Security**, scroll to the bottom, click **Open Anyway**, then confirm **Open**. (The old right-click → Open shortcut no longer works on macOS 15+.)

Given the cost/UX, the honest fallback for a v1 without a Developer ID is: **document build-from-source as the primary path and label any shared DMG as unsigned**, rather than promoting an unsigned download.

### B2 — No git tags; cannot cut a release

**Problem.** `git tag -l` is empty (verified). A GitHub Release is anchored to a tag; the CHANGELOG/compare links and release notes all assume one exists.

**Why it blocks.** No tag = no immutable "this is 1.0.0", no source archive anchor, nothing to attach the DMG to.

**Fix.** Cut an **annotated** tag *after* the CHANGELOG and version strings are finalized (B3, S1):
```sh
git tag -a v1.0.0 -m "Skelf 1.0.0"
git push origin v1.0.0
```

### B3 — Distribution has no published artifact and README has no install path

**Problem.** The DMG is git-ignored (correctly), built locally and shared by hand, with no checksum and nowhere to download from. README leads with `swift build` / `./build.sh` (developer-first) and has no end-user Download section.

**Why it blocks.** "Public open-source macOS app" with no way for a non-developer to obtain it, and (combined with B1) no guidance for the Gatekeeper prompt they'll hit, is not a credible public 1.0.

**Fix.** Publish a GitHub Release with the DMG + `SHA256SUMS` attached (see runbook §6), and add a README **Install** section (see S3). These unblock as soon as B1/B2 are resolved.

---

## 3. Should-fix (strongly recommended, not strictly blocking)

| ID | Item | What to do |
|----|------|-----------|
| **S1** | **Version single-source-of-truth + SemVer shape** | Version is hardcoded in 3 uncoordinated places: `build.sh:25` (`CFBundleShortVersionString = 1.0`), `build.sh:26` (`CFBundleVersion = 1`), and `Art.swift:236` (`"Skelf/1.0"` User-Agent). It's also `1.0`, not SemVer `1.0.0`. Define `SKELF_VERSION=1.0.0` once at the top of `build.sh`, interpolate it into the Info.plist heredoc, and have `Art.swift` read `Bundle.main.infoDictionary?["CFBundleShortVersionString"]` instead of the literal. Keep `CFBundleVersion` as a monotonic build counter. |
| **S2** | **`--version` CLI flag** | No `--version` exists and nothing reads `infoDictionary` (verified in `App.swift`). Add a `--version`/`-v` branch in `main()` (`App.swift:354-387`) printing `Skelf <CFBundleShortVersionString> (build <CFBundleVersion>)`. This makes the `bug_report.md` "Skelf version" field answerable and reinforces S1. |
| **S3** | **CHANGELOG 1.0.0 cut** | Currently only `## [Unreleased]` and a bare footer link `[Unreleased]: https://github.com/devbyshima/Skelf` (verified — not a compare/tag URL). Promote to `## [1.0.0] - 2026-06-19`, add an empty `## [Unreleased]` above it, and fix links to `[Unreleased]: .../compare/v1.0.0...HEAD` and `[1.0.0]: .../releases/tag/v1.0.0` (tag URL is correct for a first release — no prior tag to diff). |
| **S4** | **README end-user Install section** | Add an `## Install` above "Build & run": Releases link, "Requires macOS 26 (Tahoe) or later", drag-to-Applications, plus the Gatekeeper note (only if shipping unsigned). Document the undocumented `--enter <folder>` flag and label CLI args as skill **ids** (`--copy <id>`). |
| **S5** | **Release-automation workflow** | Only `ci.yml` exists. Add `.github/workflows/release.yml` on `push: tags: ['v*.*.*']`, `permissions: contents: write`, **`runs-on: macos-26`** (GA since 2026-02-26; ships Xcode 26.x + macOS 26 SDK — `macos-15` does **not** reliably carry Xcode 26). Import the Developer ID `.p12` (`apple-actions/import-codesign-certs`), sign with hardened runtime, make+sign DMG, `notarytool submit --wait`, staple, checksum, publish via `softprops/action-gh-release@v3` (use **v3/Node 24**; Node 20 is being removed 2026-09-16) with notes from the CHANGELOG. Scope secrets to a protected `release` Environment gated to tags so fork PRs can't read them. |
| **S6** | **Fix CI gate** | `ci.yml:16,34` run on `macos-15` and the build job is `continue-on-error: true` (verified) — it can't compile macOS 26 code, so CI never gates anything. Switch both jobs to `runs-on: macos-26` and drop `continue-on-error`. The CI build uses `swift build` (SwiftPM), which gets the SwiftUI macro plugin from the `xcode-select`'d Xcode 26 automatically. |
| **S7** | **Fix SwiftLint red signal** | `swiftlint lint` exits non-zero on 2 error-severity violations: `var W, H` at `Detail.swift:399`. The lint job has **no** `continue-on-error`, so CI is red on every push/PR. Rename to lowercase `w`/`h` (or `panelW`/`panelH`) and update downstream uses. Then run `swiftlint lint --fix` to clear most of the 50 cosmetic warnings. |
| **S8** | **SECURITY.md** | Missing (verified). Only gap in GitHub's 8-item Community Standards checklist. Add `SECURITY.md` with a "Supported versions" note and a private reporting path (enable GitHub private vulnerability reporting, or an email). Also add a real contact to `CODE_OF_CONDUCT.md:45-46` (currently "project maintainers", unactionable). |
| **S9** | **Owner/branding consistency** | LICENSE says "FullTime Studio"; remote owner is `devbyshima`; bundle id is `dev.fulltime.skelf`. Not contradictory but undocumented. Add one line to README: "Made by FullTime Studio (@devbyshima)". Keep `dev.fulltime.skelf` (changing it orphans caches/UserDefaults). |
| **S10** | **Stale `SkillShelf` naming** | `SKILLSHELF_DEBUG`, `[skillshelf]` log prefix (`App.swift:247-248`), `struct SkillShelfMain` (`App.swift:353`) are pre-rename leftovers. Cosmetic; rename to `SKELF_*` / `SkelfMain` in one pass. |
| **S11** | **Bare `--copy` falls through to GUI** | `--copy` with no following id (`App.swift:366`) silently launches the full GUI instead of erroring. Print a usage error to stderr and exit 1, mirroring the "no such skill" path. |

---

## 4. Nice-to-have / follow-ups (post-1.0)

- **Swift 6 migration** — ship 1.0 on Swift 5 as planned (Swift 6 surfaces 4 errors + ~30 actor-isolation warnings at `App.swift:29-161`). Track annotating `AppDelegate`/menu setup with `@MainActor` as a post-1.0 task.
- **Auto-update** — defer from 1.0. Cheapest v1.x win: in-app "Check for Updates" hitting `api.github.com/repos/devbyshima/Skelf/releases/latest`, comparing `tag_name` to `CFBundleShortVersionString` (note 60 req/hr/IP unauthenticated). Adopt **Sparkle** only when you want true background/silent updates (SwiftPM, EdDSA-signed appcast, `generate_keys` → `SUPublicEDKey`+`SUFeedURL` in Info.plist, automate `generate_appcast` in CI). Guard the Ed25519 private key.
- **Homebrew Cask** — **not a day-one item.** Casks now require signed+notarized apps (unsigned casks removed from the official tap by Sept 1, 2026; `--no-quarantine` already removed). And the notability bar for a **self-submitted** cask is ~**225 stars** (not 75). Pursue only after notarization lands *and* the repo gains traction — or ship your **own tap** (no notability gate) at launch. If/when Sparkle is added, set `auto_updates true` in the cask.
- **`LSUIElement`** — the generated Info.plist (`build.sh:14-32`) omits `LSUIElement`; a menu-bar agent normally wants `<key>LSUIElement</key><true/>`. Distribution-orthogonal but worth fixing in the same pass.
- **Markdown link scheme allow-list** — `Markdown.swift:106-107,142` renders SKILL.md links clickable with no scheme restriction (a hostile skill could embed `file://`/custom schemes). Defense-in-depth: only attach `.link` for http/https, or add an `NSTextViewDelegate` gating `textView(_:clickedOnLink:)`.
- **Privacy section in README** — three hosts contacted (api.artic.edu, www.artic.edu, github.com), only a skill keyword + standard headers sent, no telemetry, all caching local, painting fetch toggleable via Settings (`AppSupport.swift:185-188`). Strong trust story.
- **Discoverability** — repo About description; topics (`swift, swiftui, macos, macos-app, menu-bar, statusbar, utility, claude, claude-code`); homepage URL; ~1280×640 social preview (use/crop `docs/screenshot.png`). README badges (latest release, platform, min-OS, license). Set `blank_issues_enabled: false` and add `contact_links` in `.github/ISSUE_TEMPLATE/config.yml`. A demo GIF above the fold. Credit "Painting imagery courtesy of the Art Institute of Chicago, public domain."
- **Build determinism** — derive `CFBundleVersion` from `git rev-list --count HEAD` and publish the source commit SHA in release notes so each DMG is commit-traceable. Pin the Xcode version in the release workflow.

---

## 5. Decisions the maintainer must make

1. **Apple Developer Program?** Will you pay $99/yr for the Developer ID Application cert + notarization? This is the gate for a clean download. **Yes** → do B1 fully (signed + notarized + stapled DMG). **No** → 1.0 ships unsigned with documented System-Settings open flow, and Homebrew Cask is off the table.
2. **Signed+notarized vs unsigned-with-instructions for 1.0?** Direct consequence of #1. If unsigned, accept that most non-developers will bounce at the Gatekeeper wall — consider making build-from-source the primary documented path.
3. **Identity:** confirm "FullTime Studio" (LICENSE) is the intended legal copyright holder and surface the `devbyshima` ↔ FullTime Studio linkage in README. (Keep `dev.fulltime.skelf` bundle id.)
4. **Release build toolchain:** confirm the 1.0 build comes from a **stable Xcode 26**, not `/Applications/Xcode-beta.app` (the only Xcode currently on the maintainer's machine).
5. **CI runner now or later:** flip CI to `macos-26` immediately (it's GA), or stay on the broken `macos-15`/`continue-on-error` gate until release automation lands?
6. **Auto-update strategy:** none for 1.0, lightweight GitHub-API check for 1.x, or commit to Sparkle? (Affects whether you ever set `auto_updates` in a future cask.)

---

## 6. Step-by-step release runbook (cut 1.0.0)

Assumes decisions made and S1/S3/S7 changes landed. Two variants for the signing step.

```sh
# 0. PRE-FLIGHT (on a stable Xcode 26, not Xcode-beta)
sudo xcode-select -s /Applications/Xcode.app   # ensure swift build / swiftlint don't dyld-crash
git switch -c release/1.0.0                      # do not work on default branch

# 1. SET VERSION (single source of truth — S1)
#    Edit build.sh: SKELF_VERSION=1.0.0 interpolated into the Info.plist heredoc.
#    Edit Art.swift:236 to read CFBundleShortVersionString instead of "Skelf/1.0".

# 2. FINALIZE CHANGELOG (S3)
#    Promote [Unreleased] -> ## [1.0.0] - 2026-06-19, add empty [Unreleased],
#    fix footer links to compare/tag URLs.

# 3. LINT + BUILD CLEAN (S7)
swiftlint lint --fix && swiftlint lint          # must exit 0
./build.sh                                       # produces Skelf.app

# 4. SIGN
#  --- Variant A: signed + notarized (requires Developer ID) ---
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: <Name> (<TEAMID>)" Skelf.app
codesign --verify --deep --strict --verbose=4 Skelf.app     # must pass (--strict is for the .app, not the DMG)

#  --- Variant B: unsigned 1.0 (fallback) ---
#  Keep build.sh's ad-hoc sign; skip to step 7. Document the Gatekeeper flow in README.

# 5. MAKE + SIGN DMG  (Variant A)
./scripts/make-dmg.sh
codesign --force --sign "Developer ID Application: <Name> (<TEAMID>)" Skelf.dmg

# 6. NOTARIZE + STAPLE  (Variant A)
xcrun notarytool store-credentials "skelf-notary" \
  --key AuthKey_XXXX.p8 --key-id <KEYID> --issuer <ISSUER_UUID>   # one-time
xcrun notarytool submit Skelf.dmg --keychain-profile "skelf-notary" --wait
xcrun stapler staple Skelf.dmg
xcrun stapler validate Skelf.dmg
spctl -a -vv -t open Skelf.dmg                  # "accepted, source=Notarized Developer ID"

# 7. CHECKSUM
shasum -a 256 Skelf.dmg > SHA256SUMS

# 8. TAG (annotated — B2)
git tag -a v1.0.0 -m "Skelf 1.0.0"
git push origin v1.0.0

# 9. GITHUB RELEASE (draft first, attach assets, then publish)
gh release create v1.0.0 Skelf.dmg SHA256SUMS \
  --title "v1.0.0 — first public release" \
  --notes-file <(awk '/^## \[1.0.0\]/{f=1;next}/^## /{f=0}f' CHANGELOG.md) \
  --draft
#  Review the draft, attach the DMG + SHA256SUMS, set as latest, then:
gh release edit v1.0.0 --draft=false

# 10. VERIFY THE REAL DOWNLOAD (Variant A)
#  Download the DMG via Safari on a clean macOS 15 + macOS 26 machine; confirm
#  it opens with NO security block (quarantined copy — not the local build).
```

After publishing: enable **Release immutability** (GA 2025-10-28) in repo settings so the tag/assets can't be altered, and add a **GitHub ruleset** on `v*` tags restricting create/update/delete to admins (tag-protection rules are deprecated).

---

## 7. Concrete artifacts to add/change

**Edit:**
- `build.sh:25-26` — replace hardcoded `1.0`/`1` with a single `SKELF_VERSION=1.0.0` variable interpolated into the Info.plist heredoc (S1).
- `build.sh:14-32` — add `<key>LSUIElement</key><true/>` to the generated Info.plist (menu-bar agent).
- `build.sh:73` — for release builds, replace `codesign --force --deep --sign -` with Developer ID + `--options runtime --timestamp`; keep ad-hoc only behind a dev-mode/identity check (B1).
- `Sources/Skelf/Art.swift:236` — read `Bundle.main.infoDictionary?["CFBundleShortVersionString"]` instead of the `"Skelf/1.0"` literal (S1).
- `Sources/Skelf/Detail.swift:399` — rename `var W, H` → `w, h` and downstream uses; clears the 2 SwiftLint errors (S7).
- `Sources/Skelf/App.swift:354-387` — add `--version`/`-v` branch reading `infoDictionary` (S2); fix bare `--copy`/`--open`/`--enter` to error+exit 1 instead of launching GUI (S11).
- `Sources/Skelf/App.swift:247,248,353` — rename `SKILLSHELF_DEBUG`/`[skillshelf]`/`SkillShelfMain` → `SKELF_*`/`SkelfMain` (S10).
- `scripts/make-dmg.sh` — emit `shasum -a 256 Skelf.dmg > SHA256SUMS`; in the release path, sign + notarize + staple the DMG (B1).
- `CHANGELOG.md:7,28` — promote `[Unreleased]` → `## [1.0.0] - 2026-06-19`, add empty `[Unreleased]`, fix footer links to compare/tag URLs (S3).
- `README.md:14` — add `## Install` (Releases link, macOS 26 requirement, drag-to-Applications, Gatekeeper note if unsigned); document `--enter <folder>` and label args as ids; add a Privacy section and author/credit line (S4, S9).
- `.github/workflows/ci.yml:16,20,34` — switch both jobs to `runs-on: macos-26`, remove `continue-on-error: true` (S6).
- `.github/ISSUE_TEMPLATE/config.yml` — set `blank_issues_enabled: false`, add `contact_links` (Discussions + SECURITY.md).
- `CODE_OF_CONDUCT.md:45-46` — add a real enforcement contact.

**Create:**
- `SECURITY.md` — supported versions + private vulnerability reporting path (S8; only missing Community Standards item).
- `.github/workflows/release.yml` — tag-triggered (`v*.*.*`) build → sign → DMG → notarize → staple → checksum → GitHub Release on `macos-26` (S5).
- `RELEASING.md` (optional) — the runbook in §6 + the version-bump procedure, so future releases are reproducible.

**Confirm (GitHub settings, not files):** repo description, topics, homepage, social-preview image (`docs/screenshot.png`); enable Release immutability and a `v*` tag ruleset; enable Discussions if referenced by `config.yml`.
