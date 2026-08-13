// Built-in self-update. Skelf polls its GitHub Releases for a newer build, verifies the
// download against the published SHA256SUMS, swaps its own .app bundle in place, and relaunches.
//
// This needs no release infrastructure beyond what CI already publishes (Skelf.dmg + SHA256SUMS)
// and works only against the PUBLIC repo (anonymous release access). The whole flow is best-effort:
// any failure leaves the running app untouched and, for manual checks, explains what happened.

import AppKit
import CryptoKit

enum Updater {
    // The public repo that publishes Skelf.dmg + SHA256SUMS on each tagged release.
    static let owner = "devbyshima"
    static let repo = "Skelf"

    private static let lastCheckKey = "lastUpdateCheckAt"
    private static let skipVersionKey = "skipUpdateVersion"
    private static var inFlight = false
    private static var progressObs: NSKeyValueObservation?     // download progress → the window's bar

    // MARK: - Entry points

    /// Menu / Settings "Check Now": always reports the outcome, including "up to date".
    static func checkManually() { check(silent: false) }

    /// Launch + periodic background check: silent unless a non-skipped update is found, throttled
    /// to ~once a day across launches. No-op for dev builds or when the user turned it off.
    static func checkInBackgroundIfDue() {
        guard AppSettings.shared.autoCheckUpdates, currentVersion != nil else { return }
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard now - last > 23 * 3600 else { return }
        check(silent: true)
    }

    // MARK: - Check

    private static var currentVersion: Precedence? {
        semver(skelfShortVersion) == nil ? nil : semverPrecedence(skelfShortVersion)
    }

    private static func check(silent: Bool) {
        guard !inFlight else { return }
        guard let current = currentVersion else {
            if !silent { info("You’re running a development build", "Auto-update is only available in released builds.") }
            return
        }
        inFlight = true
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        fetchLatest { rel, errorMessage in
            DispatchQueue.main.async {
                inFlight = false
                guard let rel = rel else {
                    if !silent { info("Couldn’t check for updates", errorMessage ?? "Couldn’t reach GitHub.") }
                    return
                }
                guard semver(rel.version) != nil else {
                    if !silent { info("Couldn’t check for updates", "The latest release has an unexpected version (\(rel.version)).") }
                    return
                }
                if compare(semverPrecedence(rel.version), current) > 0 {
                    if silent && UserDefaults.standard.string(forKey: skipVersionKey) == rel.version { return }
                    promptUpdate(rel)
                } else if !silent {
                    info("You’re up to date", "Skelf \(skelfShortVersion) is the latest version.")
                }
            }
        }
    }

    // MARK: - Release feed

    private struct Release {
        let version: String      // tag with the leading "v" stripped, e.g. "1.1.0"
        let notes: String
        let page: URL
        let dmg: URL
        let sums: URL?
    }

    /// On the stable channel: `/releases/latest`, which GitHub defines as the newest NON-prerelease
    /// release. On the beta channel: the `/releases` list, from which we take the highest version
    /// by SemVer precedence — pre-releases included — so beta users lead production users but are
    /// still moved onto the final build once it ships (1.6.0 outranks 1.6.0-beta.2).
    private static func fetchLatest(_ done: @escaping (Release?, String?) -> Void) {
        let beta = AppSettings.shared.betaChannel
        let path = beta ? "releases?per_page=30" : "releases/latest"
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/\(path)")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Skelf/\(skelfShortVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { return done(nil, err.localizedDescription) }
            guard let http = resp as? HTTPURLResponse else { return done(nil, "No response from GitHub.") }
            guard http.statusCode == 200, let data = data else {
                return done(nil, "GitHub returned HTTP \(http.statusCode).")
            }
            let json = try? JSONSerialization.jsonObject(with: data)
            // One object on the stable path, an array on the beta path — normalize to a list.
            let objs: [[String: Any]]
            if beta {
                guard let list = json as? [[String: Any]] else { return done(nil, "Couldn’t read the release feed.") }
                objs = list.filter { ($0["draft"] as? Bool) != true }
            } else {
                guard let one = json as? [String: Any] else { return done(nil, "Couldn’t read the release feed.") }
                objs = [one]
            }
            let releases = objs.compactMap(parse)
            guard let best = releases.max(by: { compare(semverPrecedence($0.version), semverPrecedence($1.version)) < 0 }) else {
                return done(nil, beta ? "No published release has a Skelf.dmg to download."
                                      : "The latest release has no Skelf.dmg to download.")
            }
            done(best, nil)
        }.resume()
    }

    /// One release JSON object → a `Release`, or nil when it carries no downloadable DMG.
    private static func parse(_ obj: [String: Any]) -> Release? {
        guard let tag = obj["tag_name"] as? String, let assets = obj["assets"] as? [[String: Any]] else { return nil }
        func assetURL(_ name: String) -> URL? {
            (assets.first { ($0["name"] as? String) == name }?["browser_download_url"] as? String).flatMap(URL.init(string:))
        }
        guard let dmg = assetURL("Skelf.dmg") else { return nil }
        let page = (obj["html_url"] as? String).flatMap(URL.init)
            ?? URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                       notes: (obj["body"] as? String) ?? "",
                       page: page, dmg: dmg, sums: assetURL("SHA256SUMS"))
    }

    // MARK: - Prompt

    private static func promptUpdate(_ rel: Release) {
        let notes = rel.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        UpdateWindowController.shared.present(
            currentVersion: skelfShortVersion,
            newVersion: rel.version,
            notes: notes.isEmpty ? "A new version of Skelf is available. It will download, verify, and relaunch." : notes,
            onInstall: { startDownload(rel) },
            onSkip: { UserDefaults.standard.set(rel.version, forKey: skipVersionKey) },
            onOpenPage: { NSWorkspace.shared.open(rel.page) }
        )
    }

    // MARK: - Download → verify → install

    private static func startDownload(_ rel: Release) {
        let bundle = Bundle.main.bundleURL
        if bundle.path.contains("/AppTranslocation/") {
            return finishError("Skelf is running from a temporary, read-only location. Move it into your Applications folder, or open the download page to update manually.")
        }
        let parent = bundle.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: bundle.path),
              FileManager.default.isWritableFile(atPath: parent) else {
            return finishError("Skelf can’t replace itself at \(bundle.path). Open the download page to update manually.")
        }

        var req = URLRequest(url: rel.dmg)
        req.setValue("Skelf/\(skelfShortVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 60
        let task = URLSession.shared.downloadTask(with: req) { tmp, resp, err in
            DispatchQueue.main.async { progressObs?.invalidate(); progressObs = nil }
            guard let tmp = tmp, (resp as? HTTPURLResponse)?.statusCode == 200, err == nil else {
                return finishError("The download didn’t complete.")
            }
            let dmgPath = NSTemporaryDirectory() + "Skelf-update-\(rel.version).dmg"
            try? FileManager.default.removeItem(atPath: dmgPath)
            do { try FileManager.default.moveItem(at: tmp, to: URL(fileURLWithPath: dmgPath)) }
            catch { return finishError("Couldn’t save the download.") }
            verifyThenInstall(rel, dmgPath: dmgPath)
        }
        // Live download percentage into the window's progress bar.
        progressObs = task.progress.observe(\.fractionCompleted) { p, _ in
            let f = p.fractionCompleted
            DispatchQueue.main.async { UpdateWindowController.shared.phase(.downloading(f)) }
        }
        task.resume()
    }

    /// Verify the DMG against the release's SHA256SUMS before touching anything on disk.
    private static func verifyThenInstall(_ rel: Release, dmgPath: String) {
        DispatchQueue.main.async { UpdateWindowController.shared.phase(.verifying) }
        guard let sums = rel.sums else {
            // No checksum published (older release) — fall back to TLS-only trust.
            return install(rel, dmgPath: dmgPath)
        }
        var req = URLRequest(url: sums)
        req.setValue("Skelf/\(skelfShortVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let data = data, (resp as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8),
                  let expected = expectedHash(in: text, for: "Skelf.dmg") else {
                return finishError("Couldn’t verify the download’s checksum.")
            }
            guard let actual = sha256(ofFileAt: dmgPath), actual.caseInsensitiveCompare(expected) == .orderedSame else {
                try? FileManager.default.removeItem(atPath: dmgPath)
                return finishError("The download didn’t match its published checksum and was discarded.")
            }
            install(rel, dmgPath: dmgPath)
        }.resume()
    }

    /// Mount the DMG, stage a quarantine-free copy of the new app, detach, then hand off to a
    /// detached shell that waits for this process to quit, swaps the bundle, and relaunches.
    private static func install(_ rel: Release, dmgPath: String) {
        DispatchQueue.main.async { UpdateWindowController.shared.phase(.installing) }
        let mount = NSTemporaryDirectory() + "SkelfUpdateMount-\(rel.version)"
        let staging = NSTemporaryDirectory() + "SkelfUpdateStage-\(rel.version)"
        let stagedApp = staging + "/Skelf.app"
        try? FileManager.default.removeItem(atPath: mount)
        try? FileManager.default.removeItem(atPath: staging)
        try? FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)

        guard run("/usr/bin/hdiutil", ["attach", dmgPath, "-nobrowse", "-noverify", "-noautoopen", "-mountpoint", mount]).ok else {
            return finishError("Couldn’t open the downloaded disk image.")
        }
        let mountedApp = mount + "/Skelf.app"
        guard FileManager.default.fileExists(atPath: mountedApp) else {
            _ = run("/usr/bin/hdiutil", ["detach", mount, "-force"])
            return finishError("The disk image didn’t contain Skelf.")
        }
        guard run("/usr/bin/ditto", [mountedApp, stagedApp]).ok else {
            _ = run("/usr/bin/hdiutil", ["detach", mount, "-force"])
            return finishError("Couldn’t copy the new version.")
        }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stagedApp])
        _ = run("/usr/bin/hdiutil", ["detach", mount, "-force"])

        let dest = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = writeSwapScript()
        let cmd = "nohup /bin/sh \(q(script)) \(pid) \(q(stagedApp)) \(q(dest)) \(q(dmgPath)) \(q(staging)) >/dev/null 2>&1 &"
        let proc = Process()
        proc.launchPath = "/bin/sh"
        proc.arguments = ["-c", cmd]
        do { try proc.run() } catch { return finishError("Couldn’t start the installer.") }

        DispatchQueue.main.async {
            UpdateWindowController.shared.phase(.relaunching)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
        }
    }

    // The bundle swap runs after we exit so the new app isn't replacing a running executable.
    // It rolls back to the old bundle if the copy fails, then relaunches whatever's there.
    private static func writeSwapScript() -> String {
        let path = NSTemporaryDirectory() + "skelf-update-swap.sh"
        let body = """
        #!/bin/sh
        PID="$1"; SRC="$2"; DST="$3"; DMG="$4"; STAGE="$5"
        i=0
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; i=$((i+1)); [ "$i" -gt 150 ] && break; done
        sleep 0.3
        OLD="$DST.old-$$"
        if /bin/mv "$DST" "$OLD" 2>/dev/null; then
          if /usr/bin/ditto "$SRC" "$DST"; then
            /usr/bin/xattr -dr com.apple.quarantine "$DST" 2>/dev/null
            /bin/rm -rf "$OLD"
          else
            /bin/rm -rf "$DST"; /bin/mv "$OLD" "$DST"
          fi
        fi
        /usr/bin/open "$DST"
        /bin/rm -rf "$DMG" "$STAGE" "$0"
        """
        try? body.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    // MARK: - Helpers

    private static func finishError(_ message: String) {
        DispatchQueue.main.async {
            progressObs?.invalidate(); progressObs = nil
            UpdateWindowController.shared.phase(.failed(message))
        }
    }

    private static func info(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    private static func sha256(ofFileAt path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Parse a `shasum`-style line: `<hex>  Skelf.dmg`.
    private static func expectedHash(in text: String, for name: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if parts.count >= 2, parts.last == name { return parts.first }
        }
        return nil
    }

    /// Parse a dotted version (dropping any `-prerelease` suffix). Returns nil for non-numeric
    /// versions like "dev", which disables auto-update for unreleased builds.
    private static func semver(_ s: String) -> [Int]? {
        let core = s.split(separator: "-").first.map(String.init) ?? s
        let parts = core.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.map { $0! }
    }

    /// A version split for SemVer precedence: the numeric core plus its pre-release identifiers.
    private struct Precedence {
        let core: [Int]
        let pre: [String]      // empty for a final release
    }

    /// Split `1.6.0-beta.1` into core `[1, 6, 0]` and pre-release `["beta", "1"]`. A version whose
    /// core doesn't parse gets core `[]`, which ranks below everything — it never wins a `max`.
    private static func semverPrecedence(_ s: String) -> Precedence {
        let parts = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let pre = parts.count > 1 ? String(parts[1]) : ""
        return Precedence(core: semver(s) ?? [],
                          pre: pre.isEmpty ? [] : pre.split(separator: ".").map(String.init))
    }

    /// SemVer §11 precedence. Beyond the numeric core: a pre-release ranks BELOW the same core
    /// without one (1.6.0-beta.2 < 1.6.0), numeric identifiers compare numerically (beta.9 <
    /// beta.10), numeric ranks below alphanumeric, and a longer identifier list wins a tie.
    private static func compare(_ a: Precedence, _ b: Precedence) -> Int {
        for i in 0..<max(a.core.count, b.core.count) {
            let x = i < a.core.count ? a.core[i] : 0, y = i < b.core.count ? b.core[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        if a.pre.isEmpty != b.pre.isEmpty { return a.pre.isEmpty ? 1 : -1 }
        for i in 0..<min(a.pre.count, b.pre.count) {
            let x = a.pre[i], y = b.pre[i]
            if x == y { continue }
            let xn = Int(x), yn = Int(y)
            if let xn = xn, let yn = yn { return xn < yn ? -1 : 1 }
            if xn != nil { return -1 }       // numeric identifiers rank below alphanumeric ones
            if yn != nil { return 1 }
            return x < y ? -1 : 1
        }
        if a.pre.count != b.pre.count { return a.pre.count < b.pre.count ? -1 : 1 }
        return 0
    }

    @discardableResult
    private static func run(_ launch: String, _ args: [String]) -> (ok: Bool, out: String) {
        let p = Process()
        p.launchPath = launch
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (false, "") }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }

    /// Single-quote a path for safe interpolation into the `/bin/sh -c` hand-off.
    private static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
