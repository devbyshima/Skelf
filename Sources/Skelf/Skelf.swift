// Skelf — a native macOS menu-bar + window app that lists your installed
// Claude Code skills. Browse a grid of skills, click one to open its detail
// screen, and hit Copy to put its slash-command initiator (e.g. /humanizer) on
// the clipboard so you can paste it into cloud sessions.
//
// Reads live from disk and AUTO-REFRESHES via FSEvents when skills change:
//   ~/Dev/.agents/skills/<id>/SKILL.md   (name, description, version)
//   ~/Dev/.claude/skills/<id>            (symlink => enabled)
//   ~/Dev/skills-lock.json               (source repo, category from skillPath)
// Override the base dir with the SKILLS_DEV_DIR env var.
//
// The window navigation + toolbars are SwiftUI (NavigationStack + Liquid Glass
// .toolbar, bridged into the AppKit window via NSHostingController), hosting the
// AppKit grid + detail. SwiftUI's external macros (@State/@Bindable) need Xcode's
// libSwiftUIMacros plugin, which build.sh locates and passes via -plugin-path.
// Build:  ./build.sh        Run:  open Skelf.app

import AppKit
import SwiftUI
import Observation
import QuartzCore
import CoreServices

// MARK: - Model

struct Skill: Hashable {
    let id: String
    let name: String
    let description: String
    let version: String?
    let source: String
    let category: String
    let skillPath: String
    let enabled: Bool
    let fileCount: Int
    let installedAt: String
    let dirPath: String

    var initiator: String { "/" + id }
    var skillMDPath: String { dirPath + "/SKILL.md" }
    var githubURL: URL? {                       // the repo root
        guard source.contains("/") else { return nil }
        return URL(string: "https://github.com/\(source)")
    }
    /// The skill's own page in its repo (its folder), not just the repo root. Uses the
    /// `HEAD` ref so it resolves on any default branch (main, master, …).
    var skillGithubURL: URL? {
        guard source.contains("/") else { return nil }
        var path = skillPath
        for suffix in ["/SKILL.md", "SKILL.md"] where path.hasSuffix(suffix) {
            path = String(path.dropLast(suffix.count)); break
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return encoded.isEmpty
            ? URL(string: "https://github.com/\(source)")
            : URL(string: "https://github.com/\(source)/tree/HEAD/\(encoded)")
    }
    /// The creator's GitHub profile.
    var creatorGithubURL: URL? {
        guard let owner = source.split(separator: "/").first else { return nil }
        return URL(string: "https://github.com/\(owner)")
    }
}

// MARK: - Store (reads skills live from disk)

final class SkillStore {
    private(set) var skills: [Skill] = []

    var base: URL {
        if let override = ProcessInfo.processInfo.environment["SKILLS_DEV_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Dev")
    }
    var agentsDir: URL { base.appendingPathComponent(".agents/skills") }
    var claudeDir: URL { base.appendingPathComponent(".claude/skills") }

    func reload() {
        let lock = Self.parseLock(base.appendingPathComponent("skills-lock.json"))
        let fm = FileManager.default
        let dateFmt = DateFormatter(); dateFmt.dateFormat = "yyyy-MM-dd"
        var result: [Skill] = []
        let dirs = (try? fm.contentsOfDirectory(at: agentsDir,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles])) ?? []
        for dir in dirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let id = dir.lastPathComponent
            let frontmatter = Self.parseFrontmatter(dir.appendingPathComponent("SKILL.md"))
            let meta = lock[id]
            let enabled = fm.fileExists(atPath: claudeDir.appendingPathComponent(id).path)
            let files = (try? fm.contentsOfDirectory(atPath: dir.path))?.count ?? 1
            var installed = "—"
            if let attrs = try? fm.attributesOfItem(atPath: dir.path), let d = attrs[.modificationDate] as? Date {
                installed = dateFmt.string(from: d)
            }
            result.append(Skill(
                id: id,
                name: frontmatter.name ?? id,
                description: frontmatter.description ?? "",
                version: frontmatter.version,
                source: meta?.source ?? "local",
                category: Self.category(fromPath: meta?.skillPath ?? id),
                skillPath: meta?.skillPath ?? "\(id)/SKILL.md",
                enabled: enabled,
                fileCount: files,
                installedAt: installed,
                dirPath: dir.path
            ))
        }
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        skills = result
    }

    static func parseFrontmatter(_ url: URL) -> (name: String?, description: String?, version: String?) {
        var name: String? = nil, desc: String? = nil, version: String? = nil
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (name, desc, version) }
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return (name, desc, version)
        }
        var i = 1
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let rawValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if rawValue == "|" || rawValue == ">" {
                    var block: [String] = []
                    i += 1
                    while i < lines.count {
                        let l = lines[i]
                        if l.trimmingCharacters(in: .whitespaces) == "---" { break }
                        if l.hasPrefix(" ") || l.hasPrefix("\t") || l.trimmingCharacters(in: .whitespaces).isEmpty {
                            let t = l.trimmingCharacters(in: .whitespaces)
                            if !t.isEmpty { block.append(t) }
                            i += 1
                        } else { break }
                    }
                    assign(key, block.joined(separator: " "), &name, &desc, &version)
                    continue
                } else {
                    assign(key, rawValue, &name, &desc, &version)
                }
            }
            i += 1
        }
        return (name, desc, version)
    }

    private static func assign(_ key: String, _ value: String,
                               _ name: inout String?, _ desc: inout String?, _ version: inout String?) {
        let v = unquote(value)
        switch key {
        case "name": name = v
        case "description": desc = v
        case "version": version = v
        default: break
        }
    }

    private static func unquote(_ s: String) -> String {
        var t = s
        if t.count >= 2, (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }

    struct LockMeta { let source: String; let skillPath: String }

    static func parseLock(_ url: URL) -> [String: LockMeta] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let skills = obj["skills"] as? [String: Any] else { return [:] }
        var out: [String: LockMeta] = [:]
        for (k, v) in skills {
            if let d = v as? [String: Any] {
                out[k] = LockMeta(source: d["source"] as? String ?? "local",
                                  skillPath: d["skillPath"] as? String ?? "")
            }
        }
        return out
    }

    static func category(fromPath p: String) -> String {
        let parts = p.split(separator: "/").map(String.init).filter { $0 != "SKILL.md" && !$0.isEmpty }
        if parts.first == "skills" {
            let inner = Array(parts.dropFirst())
            if inner.count >= 2 { return inner[0] }
        }
        return "uncategorized"
    }
}

// MARK: - Filesystem watcher (auto-detect skill add/remove/modify via FSEvents)

final class SkillWatcher {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let onChange: () -> Void
    private var debounce: DispatchWorkItem?

    init(paths: [String], onChange: @escaping () -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    func start() {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { (_, info, _, _, _, _) in
            guard let info = info else { return }
            Unmanaged<SkillWatcher>.fromOpaque(info).takeUnretainedValue().scheduleReload()
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                                               existing as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               0.3, flags) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    private func scheduleReload() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func stop() {
        if let stream = stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
}

// MARK: - Favorites (persisted pins — sort first everywhere)

final class Favorites {
    private let key = "favoriteSkillIDs"
    private(set) var ids: Set<String>
    var onChange: (() -> Void)?

    init() { ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }

    func isFavorite(_ id: String) -> Bool { ids.contains(id) }

    func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        UserDefaults.standard.set(Array(ids), forKey: key)
        onChange?()
    }

    /// Favorites first (alphabetical), then the rest (alphabetical).
    func ordered(_ skills: [Skill]) -> [Skill] {
        skills.sorted { a, b in
            let fa = ids.contains(a.id), fb = ids.contains(b.id)
            if fa != fb { return fa }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

// MARK: - Folders (persisted DISPLAY-ONLY organization overlay; never touches Claude config)

final class FolderStore {
    struct Node: Codable, Equatable {
        var id: String
        var name: String
        var parent: String?      // nil only for root
        var folders: [String]    // child folder ids (ordered)
        var skills: [String]     // skill ids placed here (ordered)
        var autoCreator: String? // non-nil => auto-folder grouping one creator's skills
        var showInMenuBar: Bool  // user opted this folder into the menu-bar popover

        enum CodingKeys: String, CodingKey { case id, name, parent, folders, skills, autoCreator, showInMenuBar }
        init(id: String, name: String, parent: String?, folders: [String], skills: [String],
             autoCreator: String? = nil, showInMenuBar: Bool = false) {
            self.id = id; self.name = name; self.parent = parent; self.folders = folders
            self.skills = skills; self.autoCreator = autoCreator; self.showInMenuBar = showInMenuBar
        }
        init(from d: Decoder) throws {                     // tolerant of older saved trees
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            parent = try c.decodeIfPresent(String.self, forKey: .parent)
            folders = try c.decode([String].self, forKey: .folders)
            skills = try c.decode([String].self, forKey: .skills)
            autoCreator = try c.decodeIfPresent(String.self, forKey: .autoCreator)
            showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? false
        }
    }

    /// The creator/owner shown as the auto-folder name, derived from a skill's source.
    static func creatorName(_ source: String) -> String {
        if source.isEmpty || source == "local" { return "Local" }
        return source.split(separator: "/").first.map(String.init) ?? source
    }

    private(set) var nodes: [String: Node] = [:]
    let rootId = "root"
    var onChange: (() -> Void)?
    weak var undoManager: UndoManager?
    private let key = "folderTreeV1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Node].self, from: data) {
            nodes = decoded
        }
        if nodes[rootId] == nil {
            nodes[rootId] = Node(id: rootId, name: "All Skills", parent: nil, folders: [], skills: [])
        }
    }

    private func persist(notify: Bool = true) {
        if let data = try? JSONEncoder().encode(nodes) { UserDefaults.standard.set(data, forKey: key) }
        if notify { onChange?() }
    }

    /// Run a mutation, register an undo that restores the whole tree, and persist —
    /// only if anything actually changed.
    private func apply(_ name: String, _ change: () -> Void) {
        let before = nodes
        change()
        guard nodes != before else { return }
        registerUndo(restoring: before, name: name)
        persist()
    }

    private func registerUndo(restoring before: [String: Node], name: String) {
        undoManager?.registerUndo(withTarget: self) { store in
            let current = store.nodes
            store.nodes = before
            store.registerUndo(restoring: current, name: name)   // makes it redoable
            store.persist()
        }
        undoManager?.setActionName(name)
    }

    // --- reads ---
    func node(_ id: String) -> Node? { nodes[id] }
    func childFolders(of id: String) -> [Node] { (nodes[id]?.folders ?? []).compactMap { nodes[$0] } }
    func skillIds(in id: String) -> [String] { nodes[id]?.skills ?? [] }

    func path(to id: String) -> [Node] {
        var out: [Node] = []
        var cur: String? = id
        while let c = cur, let n = nodes[c] { out.insert(n, at: 0); cur = n.parent }
        return out
    }

    func isDescendant(_ candidate: String, of ancestor: String) -> Bool {
        var cur: String? = candidate
        while let c = cur { if c == ancestor { return true }; cur = nodes[c]?.parent }
        return false
    }

    // --- mutations (each registers undo via apply) ---
    @discardableResult
    func createFolder(name: String, in parentId: String) -> String? {
        guard nodes[parentId] != nil else { return nil }
        let id = "f-" + UUID().uuidString.prefix(8)
        apply("New Folder") {
            nodes[id] = Node(id: id, name: name, parent: parentId, folders: [], skills: [])
            nodes[parentId]?.folders.append(id)
        }
        return id
    }

    func rename(_ id: String, to name: String) {
        guard id != rootId, nodes[id] != nil, !name.isEmpty else { return }
        apply("Rename Folder") { nodes[id]?.name = name }
    }

    func deleteFolder(_ id: String) {
        guard id != rootId, let n = nodes[id], let p = n.parent else { return }
        apply("Delete Folder") {
            for sid in n.skills where !(nodes[p]?.skills.contains(sid) ?? true) { nodes[p]?.skills.append(sid) }
            for cf in n.folders { nodes[cf]?.parent = p; nodes[p]?.folders.append(cf) }
            nodes[p]?.folders.removeAll { $0 == id }
            nodes[id] = nil
        }
    }

    func moveFolder(_ id: String, to newParent: String) {
        guard id != rootId, id != newParent, let oldP = nodes[id]?.parent, nodes[newParent] != nil,
              !isDescendant(newParent, of: id) else { return }
        apply("Move Folder") {
            nodes[oldP]?.folders.removeAll { $0 == id }
            nodes[id]?.parent = newParent
            nodes[newParent]?.folders.append(id)
        }
    }

    func moveSkill(_ skillId: String, from: String, to: String) {
        guard from != to else { return }
        apply("Move Skill") {
            nodes[from]?.skills.removeAll { $0 == skillId }
            if !(nodes[to]?.skills.contains(skillId) ?? true) { nodes[to]?.skills.append(skillId) }
        }
    }

    func copySkill(_ skillId: String, to: String) {
        apply("Copy Skill") {
            if !(nodes[to]?.skills.contains(skillId) ?? true) { nodes[to]?.skills.append(skillId) }
        }
    }

    func reorderSkill(_ id: String, in folder: String, before anchorId: String?) {
        guard nodes[folder]?.skills != nil else { return }
        apply("Reorder") {
            var arr = nodes[folder]!.skills
            arr.removeAll { $0 == id }
            if let a = anchorId, let i = arr.firstIndex(of: a) { arr.insert(id, at: i) } else { arr.append(id) }
            nodes[folder]?.skills = arr
        }
    }

    func reorderFolder(_ id: String, in parent: String, before anchorId: String?) {
        guard nodes[parent]?.folders != nil else { return }
        apply("Reorder") {
            var arr = nodes[parent]!.folders
            arr.removeAll { $0 == id }
            if let a = anchorId, let i = arr.firstIndex(of: a) { arr.insert(id, at: i) } else { arr.append(id) }
            nodes[parent]?.folders = arr
        }
    }

    /// Keep the overlay consistent with what's actually installed (called on every reload).
    func syncInstalled(_ installed: Set<String>) {
        var changed = false
        for (k, var n) in nodes {
            let before = n.skills.count
            n.skills.removeAll { !installed.contains($0) }
            if n.skills.count != before { nodes[k] = n; changed = true }
        }
        let placed = Set(nodes.values.flatMap { $0.skills })
        for sid in installed where !placed.contains(sid) {
            nodes[rootId]?.skills.append(sid); changed = true
        }
        if changed { persist(notify: false) }
    }

    /// Group skills under their creator — but only when the grouping is meaningful:
    /// the skill's `owner/repo` source must be VERIFIED to exist on GitHub (so we can
    /// actually attribute it) AND that owner must have ≥2 installed skills. Skills whose
    /// GitHub page can't be confirmed, `local`, sourceless, and singletons stay loose at
    /// root. Only skills at root are touched — anything the user filed is left alone.
    /// Auto-folders that stop being valid are dissolved. Runs on every reload (+ again
    /// as background GitHub verification resolves).
    func autoCategorize(_ installed: [Skill], isVerified: (Skill) -> Bool) {
        var changed = false
        func creator(of s: Skill) -> String? {
            guard s.source.contains("/"), isVerified(s) else { return nil }
            return s.source.split(separator: "/").first.map(String.init)
        }
        let creatorOf = Dictionary(uniqueKeysWithValues: installed.compactMap { s in creator(of: s).map { (s.id, $0) } })
        var counts: [String: Int] = [:]
        for c in creatorOf.values { counts[c, default: 0] += 1 }
        let valid = Set(counts.filter { $0.value >= 2 }.keys)

        // dissolve auto-folders whose creator is no longer valid → skills back to root
        for (id, n) in nodes where n.autoCreator != nil && !valid.contains(n.autoCreator ?? "") {
            for sid in n.skills where !(nodes[rootId]?.skills.contains(sid) ?? true) { nodes[rootId]?.skills.append(sid) }
            for cf in n.folders { nodes[cf]?.parent = rootId; nodes[rootId]?.folders.append(cf) }
            nodes[rootId]?.folders.removeAll { $0 == id }
            nodes[id] = nil
            changed = true
        }

        func autoFolderId(for creator: String) -> String {
            if let existing = nodes.values.first(where: { $0.autoCreator == creator }) { return existing.id }
            let id = "auto-" + UUID().uuidString.prefix(8)
            nodes[id] = Node(id: id, name: creator, parent: rootId, folders: [], skills: [], autoCreator: creator)
            nodes[rootId]?.folders.append(id)
            changed = true
            return id
        }

        for sid in (nodes[rootId]?.skills ?? []) {
            guard let c = creatorOf[sid], valid.contains(c) else { continue }   // singletons/local stay at root
            let fid = autoFolderId(for: c)
            nodes[rootId]?.skills.removeAll { $0 == sid }
            if !(nodes[fid]?.skills.contains(sid) ?? true) { nodes[fid]?.skills.append(sid) }
            changed = true
        }

        // drop auto-folders that ended up empty
        for (id, n) in nodes where n.autoCreator != nil && n.skills.isEmpty && n.folders.isEmpty {
            if let p = n.parent { nodes[p]?.folders.removeAll { $0 == id } }
            nodes[id] = nil
            changed = true
        }
        if changed { persist(notify: false) }
    }

    // --- menu-bar opt-in (folders are hidden from the popover until the user adds them) ---
    func showsInMenuBar(_ id: String) -> Bool { nodes[id]?.showInMenuBar ?? false }

    func setShowInMenuBar(_ id: String, _ on: Bool) {
        guard id != rootId, nodes[id] != nil else { return }
        apply(on ? "Add to Menu Bar" : "Remove from Menu Bar") { nodes[id]?.showInMenuBar = on }
    }

    /// Folders the user has opted into the menu-bar popover (flat, alphabetical).
    func menuBarFolders() -> [Node] {
        nodes.values.filter { $0.showInMenuBar }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// A row in the folder-navigating grid: a sub-folder or a skill.
enum GridEntry {
    case folder(FolderStore.Node)
    case skill(Skill)
}

// Drag-and-drop payload type for grid items ("skill:<id>" / "folder:<id>").
let skelfEntryType = NSPasteboard.PasteboardType("dev.fulltime.skelf.entry")

// MARK: - Shared helpers

enum Palette {
    static func hue(_ s: String) -> CGFloat {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) ^ UInt64(b) }
        return CGFloat(h % 360) / 360.0
    }
    static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == "_" })
        let letters = parts.prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
        return letters.isEmpty ? String(name.prefix(1)).uppercased() : letters
    }
    static func gradientColors(_ name: String) -> [CGColor] {
        let h = hue(name)
        return [NSColor(hue: h, saturation: 0.60, brightness: 0.96, alpha: 1).cgColor,
                NSColor(hue: fmod(h + 0.09, 1.0), saturation: 0.72, brightness: 0.76, alpha: 1).cgColor]
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

// A view whose single gradient sublayer always tracks its bounds (monogram tile).
final class GradientView: NSView {
    let gradient = CAGradientLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        layer?.addSublayer(gradient)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); gradient.frame = bounds }
}

// Scale a layer's `transform` around its own centre — avoids anchorPoint juggling
// inside Auto Layout (settles back to identity, so layout isn't disturbed).
func centerScale(_ layer: CALayer, _ s: CGFloat) -> CATransform3D {
    let w = layer.bounds.width, h = layer.bounds.height
    var t = CATransform3DIdentity
    t = CATransform3DTranslate(t, w / 2, h / 2, 0)
    t = CATransform3DScale(t, s, s, 1)
    t = CATransform3DTranslate(t, -w / 2, -h / 2, 0)
    return t
}

// A springy "pop" — squash to `from`, then overshoot back to rest (12-principles squash & stretch).
func springPop(_ layer: CALayer?, from: CGFloat = 0.9, damping: CGFloat = 11, stiffness: CGFloat = 320, mass: CGFloat = 0.85) {
    guard let layer = layer, layer.bounds.width > 1 else { return }
    let a = CASpringAnimation(keyPath: "transform")
    a.fromValue = centerScale(layer, from)
    a.toValue = CATransform3DIdentity
    a.damping = damping
    a.stiffness = stiffness
    a.mass = mass
    a.duration = a.settlingDuration
    layer.add(a, forKey: "pop")
}

// Subtle UI sounds, gated behind a setting (off by default). Uses built-in system sounds.
enum Sound {
    static var enabled = UserDefaults.standard.bool(forKey: "soundEnabled")   // default false
    private static var cache: [String: NSSound] = [:]

    static func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "soundEnabled")
        if on { play(.copy) }   // a preview when you switch it on
    }

    enum Cue: String { case copy = "Tink", move = "Pop" }

    static func play(_ cue: Cue, volume: Float = 0.4) {
        guard enabled else { return }
        let s = cache[cue.rawValue] ?? NSSound(named: NSSound.Name(cue.rawValue))
        cache[cue.rawValue] = s
        s?.volume = volume
        if s?.isPlaying == true { s?.stop() }
        s?.currentTime = 0
        s?.play()
    }
}

// A Liquid Glass card whose corners are concentric with their container (macOS 27).
final class GlassCardView: NSGlassEffectView {
    @available(macOS 27.0, *)
    override var cornerConfiguration: NSViewCornerConfiguration? {
        .uniformCorners(radius: .containerConcentric(10))
    }
}

// Verifies that a skill's actual GitHub page exists (HEAD the skill's /tree/HEAD/<path>
// URL — which also proves the repo and owner exist). Only skills whose page is confirmed
// may be auto-filed under a creator; otherwise we can't say who the skill belongs to, so
// it stays unfiled. Confirmed URLs persist (UserDefaults); 404s/errors stay in memory so
// a renamed path or flaky network can re-resolve on a future launch. Checks are capped at
// a few concurrent requests so a large library doesn't hammer GitHub.
final class GitHubVerifier {
    static let shared = GitHubVerifier()
    private let key = "verifiedPagesV1"
    private var verified: Set<String>
    private var notFound: Set<String> = []
    private var inflight: Set<String> = []
    private var queued: [(String, () -> Void)] = []
    private let maxInflight = 5

    init() { verified = Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }

    /// true = page exists, false = confirmed missing (404), nil = not checked yet.
    func status(_ urlString: String) -> Bool? {
        if verified.contains(urlString) { return true }
        if notFound.contains(urlString) { return false }
        return nil
    }

    /// HEAD-check the URL (throttled); calls back on the main queue once resolved (or
    /// immediately if already known). Must be called on the main queue.
    func verify(_ urlString: String, completion: @escaping () -> Void) {
        if status(urlString) != nil { completion(); return }
        queued.append((urlString, completion))
        pump()
    }

    private func pump() {
        while inflight.count < maxInflight, !queued.isEmpty {
            let (s, done) = queued.removeFirst()
            if status(s) != nil || inflight.contains(s) { done(); continue }
            start(s, done)
        }
    }

    private func start(_ s: String, _ completion: @escaping () -> Void) {
        guard let url = URL(string: s) else { notFound.insert(s); completion(); return }
        inflight.insert(s)
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.inflight.remove(s)
                if let code = (resp as? HTTPURLResponse)?.statusCode {
                    if code == 200 {
                        self.verified.insert(s)
                        UserDefaults.standard.set(Array(self.verified), forKey: self.key)
                    } else if code == 404 || code == 451 {
                        self.notFound.insert(s)
                    }   // rate-limit / 5xx / transient: leave unknown, retry next launch
                }
                completion()
                self.pump()
            }
        }.resume()
    }
}

// MARK: - Grid tile

// Fetches + disk-caches a creator's public GitHub avatar (no token needed:
// https://github.com/<user>.png). Memory + on-disk cache keep scrolling cheap.
final class AvatarStore {
    static let shared = AvatarStore()
    private var mem: [String: NSImage] = [:]
    private var failed: Set<String> = []
    private var inflight: Set<String> = []
    private let dir: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        dir = base.appendingPathComponent("dev.fulltime.skelf/avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func diskURL(_ creator: String) -> URL {
        dir.appendingPathComponent(creator.replacingOccurrences(of: "/", with: "_") + ".png")
    }

    /// Synchronous cache hit (memory, then disk); nil if not fetched yet.
    func cached(_ creator: String) -> NSImage? {
        if let i = mem[creator] { return i }
        if let i = NSImage(contentsOf: diskURL(creator)) { mem[creator] = i; return i }
        return nil
    }

    /// Fetch if needed; calls back on the main queue with the avatar (or nil). Must be called on main.
    func fetch(_ creator: String, completion: @escaping (NSImage?) -> Void) {
        if let i = cached(creator) { completion(i); return }
        if failed.contains(creator) { completion(nil); return }
        if inflight.contains(creator) { return }   // a fetch is already running
        guard let url = URL(string: "https://github.com/\(creator).png?size=400") else { completion(nil); return }
        inflight.insert(creator)
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.inflight.remove(creator)
                if let data = data, let img = NSImage(data: data) {
                    try? data.write(to: self.diskURL(creator))
                    self.mem[creator] = img
                    completion(img)
                } else {
                    self.failed.insert(creator)
                    completion(nil)
                }
            }
        }.resume()
    }
}

// A skill/folder "image": a single cached bitmap layer (creator avatar, or a
// pre-rendered gradient fallback) + a bottom scrim. No live gradients/text layers,
// so scrolling stays smooth.
final class SkillArtView: NSView {
    private let imageLayer = CALayer()
    private let scrim = CAGradientLayer()
    var showScrim = true { didSet { scrim.isHidden = !showScrim } }
    private static var gradientCache: [String: CGImage] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        scrim.startPoint = CGPoint(x: 0.5, y: 0.0); scrim.endPoint = CGPoint(x: 0.5, y: 1.0)
        scrim.colors = [NSColor.black.withAlphaComponent(0.80).cgColor,
                        NSColor.black.withAlphaComponent(0.14).cgColor,
                        NSColor.clear.cgColor]
        scrim.locations = [0.0, 0.5, 1.0]
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(scrim)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); imageLayer.frame = bounds; scrim.frame = bounds }

    func setGradient(_ name: String, monogram: Bool = true) {
        imageLayer.contents = Self.gradientImage(name, monogram: monogram)
    }
    func setAvatar(_ image: NSImage) {
        var r = CGRect(origin: .zero, size: image.size)
        imageLayer.contents = image.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }

    static func gradientImage(_ name: String, monogram: Bool) -> CGImage {
        let key = name + (monogram ? "#m" : "")
        if let c = gradientCache[key] { return c }
        let size = CGSize(width: 320, height: 420)
        let img = NSImage(size: size)
        img.lockFocus()
        let cols = Palette.gradientColors(name).compactMap { NSColor(cgColor: $0) }
        if cols.count >= 2, let g = NSGradient(starting: cols[0], ending: cols[1]) {
            g.draw(in: NSRect(origin: .zero, size: size), angle: 55)
        }
        if monogram {
            let initials = Palette.initials(name) as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size.width * 0.46, weight: .heavy),
                .foregroundColor: NSColor.white.withAlphaComponent(0.17)]
            let ss = initials.size(withAttributes: attrs)
            initials.draw(at: NSPoint(x: (size.width - ss.width) / 2, y: size.height * 0.46), withAttributes: attrs)
        }
        img.unlockFocus()
        var r = CGRect(origin: .zero, size: size)
        return img.cgImage(forProposedRect: &r, context: nil, hints: nil) ?? CGImage.empty
    }
}

private extension CGImage {
    static var empty: CGImage {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
}

// The card's root view: rounded, with a soft drop shadow that fades in on hover.
final class CardRootView: NSView {
    var corner: CGFloat = 22
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        layer?.shadowRadius = 16
        layer?.shadowOpacity = 0
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: corner, cornerHeight: corner, transform: nil)
    }
}

// A Liquid-Glass circular control overlaid on a card (favorite / ⋯).
// A real Liquid-Glass circular control overlaid on a card (favorite / ⋯). To keep a
// gridful of them performant, the card groups its glass controls inside an
// NSGlassEffectContainerView (see makeGlassControls) so they share ONE backdrop
// sampling pass instead of one each.
final class GlassCircleButton: NSView {
    let button = NSButton()
    let glass = NSGlassEffectView()
    init(symbol: String, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imageScaling = .scaleProportionallyDown
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.contentTintColor = .white
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        button.target = target
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = 15
        if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
        glass.contentView = button
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 30),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// Group glass controls into one NSGlassEffectContainerView → a single sampling pass.
// container.spacing = 0 keeps each control a distinct perfect circle (no liquid merge).
func makeGlassControls(_ circles: [GlassCircleButton], spacing: CGFloat = 7) -> NSView {
    let row = NSStackView(views: circles)
    row.orientation = .horizontal
    row.spacing = spacing
    row.translatesAutoresizingMaskIntoConstraints = false
    let container = NSGlassEffectContainerView()
    container.spacing = 0
    container.contentView = row
    container.translatesAutoresizingMaskIntoConstraints = false
    return container
}

// MARK: - Grid tile (skill card — creator avatar background, product-card style)

final class SkillGridItem: NSCollectionViewItem {
    private let art = SkillArtView()
    private var favCircle: GlassCircleButton!
    private var menuCircle: GlassCircleButton!
    private let nameLabel = NSTextField(labelWithString: "")
    private let initiatorBox = NSView()
    private let initiatorLabel = NSTextField(labelWithString: "")
    private let descLabel = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton()
    private var hovering = false
    private var artKey = ""
    private(set) var skillId = ""
    private var isFav = false
    var onMenu: ((NSView) -> Void)?
    var onToggleFavorite: (() -> Void)?
    var onCopy: (() -> Void)?

    override func loadView() {
        let root = CardRootView()
        art.translatesAutoresizingMaskIntoConstraints = false
        art.layer?.cornerRadius = 22
        root.addSubview(art)

        favCircle = GlassCircleButton(symbol: "star", target: self, action: #selector(favClicked))
        menuCircle = GlassCircleButton(symbol: "ellipsis", target: self, action: #selector(menuClicked))
        let controls = makeGlassControls([favCircle, menuCircle])   // one shared glass sampling pass
        root.addSubview(controls)

        nameLabel.font = .systemFont(ofSize: 17, weight: .bold)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(nameLabel)

        initiatorBox.wantsLayer = true
        initiatorBox.layer?.cornerRadius = 11
        initiatorBox.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.44).cgColor
        initiatorBox.translatesAutoresizingMaskIntoConstraints = false
        initiatorLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        initiatorLabel.textColor = .white
        initiatorLabel.lineBreakMode = .byTruncatingTail
        initiatorLabel.translatesAutoresizingMaskIntoConstraints = false
        initiatorBox.addSubview(initiatorLabel)
        root.addSubview(initiatorBox)

        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = NSColor.white.withAlphaComponent(0.82)
        descLabel.maximumNumberOfLines = 2
        descLabel.lineBreakMode = .byTruncatingTail
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(descLabel)

        copyButton.isBordered = false
        copyButton.wantsLayer = true
        copyButton.layer?.cornerRadius = 19
        copyButton.layer?.backgroundColor = NSColor.white.cgColor
        copyButton.bezelStyle = .regularSquare
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        setCopyTitle("Copy")
        root.addSubview(copyButton)

        NSLayoutConstraint.activate([
            art.topAnchor.constraint(equalTo: root.topAnchor),
            art.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            art.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            art.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            controls.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            controls.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),

            copyButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            copyButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            copyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            copyButton.heightAnchor.constraint(equalToConstant: 40),

            descLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            descLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            descLabel.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -10),

            nameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            nameLabel.bottomAnchor.constraint(equalTo: descLabel.topAnchor, constant: -6),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: initiatorBox.leadingAnchor, constant: -8),

            initiatorBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            initiatorBox.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            initiatorBox.heightAnchor.constraint(equalToConstant: 22),
            initiatorBox.widthAnchor.constraint(lessThanOrEqualToConstant: 104),
            initiatorLabel.leadingAnchor.constraint(equalTo: initiatorBox.leadingAnchor, constant: 9),
            initiatorLabel.trailingAnchor.constraint(equalTo: initiatorBox.trailingAnchor, constant: -9),
            initiatorLabel.centerYAnchor.constraint(equalTo: initiatorBox.centerYAnchor),
        ])
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        initiatorBox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        initiatorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
        view = root
    }

    private func setCopyTitle(_ s: String) {
        copyButton.attributedTitle = NSAttributedString(string: s,
            attributes: [.foregroundColor: NSColor.black, .font: NSFont.systemFont(ofSize: 14, weight: .bold)])
    }

    func configure(_ skill: Skill, isFavorite: Bool, verified: Bool) {
        skillId = skill.id
        // Only show the creator's avatar once the skill's page is verified to belong to
        // them — unverified/removed skills fall back to the generated gradient.
        let creator = (verified && skill.source.contains("/")) ? skill.source.split(separator: "/").first.map(String.init) : nil
        artKey = creator ?? ("grad:" + skill.name)
        if let creator = creator, let img = AvatarStore.shared.cached(creator) {
            art.setAvatar(img)
        } else {
            art.setGradient(skill.name)
            if let creator = creator {
                let key = artKey
                AvatarStore.shared.fetch(creator) { [weak self] img in
                    guard let self = self, self.artKey == key, let img = img else { return }
                    self.art.setAvatar(img)
                }
            }
        }
        nameLabel.stringValue = skill.name
        initiatorLabel.stringValue = skill.enabled ? skill.category : "off"
        initiatorBox.layer?.backgroundColor = (skill.enabled ? NSColor.black.withAlphaComponent(0.44)
                                                             : NSColor.systemRed.withAlphaComponent(0.55)).cgColor
        descLabel.stringValue = skill.description.isEmpty ? "No description in SKILL.md." : skill.description
        setFavorite(isFavorite, animated: false)
        setCopyTitle("Copy")
        view.alphaValue = skill.enabled ? 1.0 : 0.62
        view.toolTip = "\(skill.initiator)\n\n\(skill.description)"
        resetHover()
    }

    /// Update the star, optionally with a springy pop (used when the user toggles it).
    func setFavorite(_ on: Bool, animated: Bool) {
        isFav = on
        favCircle.button.image = NSImage(systemSymbolName: on ? "star.fill" : "star",
                                         accessibilityDescription: on ? "Favorited" : "Favorite")
        favCircle.button.contentTintColor = on ? .systemYellow : .white
        if animated { springPop(favCircle.layer, from: on ? 0.5 : 0.86, damping: 9, stiffness: 380) }
    }

    @objc private func favClicked() {
        setFavorite(!isFav, animated: true)   // animate in place first…
        onToggleFavorite?()                    // …then persist (no destructive grid reload)
    }
    @objc private func menuClicked() { onMenu?(menuCircle) }
    @objc private func copyClicked() {
        onCopy?()
        springPop(copyButton.layer, from: 0.9)
        setCopyTitle("Copied ✓")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in self?.setCopyTitle("Copy") }
    }

    func pressPop() { springPop(view.layer, from: 0.97) }

    private func resetHover() {
        hovering = false
        view.layer?.transform = CATransform3DIdentity
        view.layer?.shadowOpacity = 0
        view.layer?.zPosition = 0
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; applyHover() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyHover() }
    private func applyHover() {
        guard let l = view.layer else { return }
        l.zPosition = hovering ? 1 : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: hovering ? .easeOut : .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            l.transform = hovering ? centerScale(l, 1.04) : CATransform3DIdentity
            l.shadowOpacity = hovering ? 0.42 : 0.0
        }
    }
    override var isSelected: Bool {
        didSet {
            art.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
            art.layer?.borderWidth = isSelected ? 2 : 0
        }
    }
}

// MARK: - Folder tile (same card shape, gradient + folder glyph)

final class FolderGridItem: NSCollectionViewItem {
    private let art = SkillArtView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private var menuCircle: GlassCircleButton!
    private var hovering = false
    private var artKey = ""
    var onMenu: ((NSView) -> Void)?

    override func loadView() {
        let root = CardRootView()
        art.translatesAutoresizingMaskIntoConstraints = false
        art.layer?.cornerRadius = 22
        root.addSubview(art)

        menuCircle = GlassCircleButton(symbol: "ellipsis", target: self, action: #selector(menuClicked))
        let controls = makeGlassControls([menuCircle])   // same glass treatment as skill cards
        root.addSubview(controls)

        nameLabel.font = .systemFont(ofSize: 17, weight: .bold)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(nameLabel)

        countLabel.font = .systemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(countLabel)

        NSLayoutConstraint.activate([
            art.topAnchor.constraint(equalTo: root.topAnchor),
            art.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            art.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            art.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            controls.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            controls.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),

            countLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            countLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            countLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            nameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            nameLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            nameLabel.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -4),
        ])
        root.addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
        view = root
    }

    func configure(_ node: FolderStore.Node, inMenuBar: Bool) {
        // creator folders wear the creator's avatar; user folders get a gradient
        if let creator = node.autoCreator {
            artKey = creator
            if let img = AvatarStore.shared.cached(creator) { art.setAvatar(img) }
            else {
                art.setGradient(node.name)
                let key = creator
                AvatarStore.shared.fetch(creator) { [weak self] img in
                    guard let self = self, self.artKey == key, let img = img else { return }
                    self.art.setAvatar(img)
                }
            }
        } else {
            artKey = "grad:" + node.name
            art.setGradient(node.name)
        }
        nameLabel.stringValue = node.name
        let s = node.skills.count, f = node.folders.count
        var parts: [String] = []
        if f > 0 { parts.append("\(f) folder\(f == 1 ? "" : "s")") }
        parts.append("\(s) skill\(s == 1 ? "" : "s")")
        countLabel.stringValue = parts.joined(separator: " · ")
        view.toolTip = node.name
        resetHover()
    }

    @objc private func menuClicked() { onMenu?(menuCircle) }
    func pressPop() { springPop(view.layer, from: 0.97) }

    private func resetHover() {
        hovering = false
        view.layer?.transform = CATransform3DIdentity
        view.layer?.shadowOpacity = 0
        view.layer?.zPosition = 0
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; applyHover() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyHover() }
    private func applyHover() {
        guard let l = view.layer else { return }
        l.zPosition = hovering ? 1 : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: hovering ? .easeOut : .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            l.transform = hovering ? centerScale(l, 1.04) : CATransform3DIdentity
            l.shadowOpacity = hovering ? 0.42 : 0.0
        }
    }
    override var isSelected: Bool {
        didSet {
            art.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
            art.layer?.borderWidth = isSelected ? 2 : 0
        }
    }
}

// MARK: - Detail screen

// Semantic-font helpers (respect the system text-size ramp instead of magic numbers).
func skelfFont(_ style: NSFont.TextStyle, _ weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
}
func skelfMono(_ style: NSFont.TextStyle, _ weight: NSFont.Weight = .medium) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
}

// An opaque bento card: subtle fill + hairline border + concentric corner (content
// surface — deliberately NOT Liquid Glass, which is reserved for the primary action).
final class MetaCardView: NSView {
    private let keyLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")

    init(key: String, value: String, mono: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        keyLabel.stringValue = key.uppercased()
        keyLabel.font = skelfFont(.caption2, .semibold)
        keyLabel.textColor = .tertiaryLabelColor
        keyLabel.lineBreakMode = .byTruncatingTail
        keyLabel.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.stringValue = value
        valueLabel.font = mono ? skelfMono(.callout, .regular) : skelfFont(.body)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = mono ? .byTruncatingMiddle : .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [keyLabel, valueLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
        keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
}

// MARK: - Detail screen

// Split a SKILL.md into its YAML-ish frontmatter rows and the markdown body.
func splitFrontmatter(_ text: String) -> (rows: [(String, String)], body: String) {
    let lines = text.components(separatedBy: "\n")
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return ([], text) }
    var i = 1
    var rows: [(String, String)] = []
    while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
        let line = lines[i]
        if !line.hasPrefix(" "), !line.hasPrefix("\t"), let c = line.firstIndex(of: ":") {
            let k = String(line[..<c]).trimmingCharacters(in: .whitespaces)
            var v = String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
            if v == "|" || v == ">" { v = "" }
            if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")), v.count >= 2 {
                v = String(v.dropFirst().dropLast())
            }
            rows.append((k, v))
        }
        i += 1
    }
    let body = i + 1 < lines.count ? lines[(i + 1)...].joined(separator: "\n") : ""
    return (rows, body)
}

// --- a small GitHub-flavoured markdown → NSAttributedString renderer (inline:
// bold/italic/code/links; block: headings, lists, code fences, blockquotes) ---

private func mdBold(_ f: NSFont) -> NSFont { NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
private func mdItalic(_ f: NSFont) -> NSFont { NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }

private func mdInline(_ s: String, base: NSFont, color: NSColor) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let chars = Array(s)
    var i = 0
    func emit(_ str: String, _ font: NSFont, _ col: NSColor, link: String? = nil, code: Bool = false) {
        var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: col]
        if let link = link, let u = URL(string: link) {
            a[.link] = u; a[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if code { a[.backgroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.16) }
        out.append(NSAttributedString(string: str, attributes: a))
    }
    while i < chars.count {
        let c = chars[i]
        if c == "`" {
            var j = i + 1, buf = ""
            while j < chars.count, chars[j] != "`" { buf.append(chars[j]); j += 1 }
            if j < chars.count {
                emit(buf, .monospacedSystemFont(ofSize: base.pointSize - 0.5, weight: .regular), color, code: true)
                i = j + 1; continue
            }
        }
        if c == "*" || c == "_" {
            let isDouble = (i + 1 < chars.count && chars[i + 1] == c)
            let marker = isDouble ? String([c, c]) : String(c)
            let rest = String(chars[(i + marker.count)...])
            if let r = rest.range(of: marker) {
                let inner = String(rest[..<r.lowerBound])
                if !inner.isEmpty {
                    emit(inner, isDouble ? mdBold(base) : mdItalic(base), color)
                    i += marker.count + inner.count + marker.count; continue
                }
            }
        }
        if c == "[" {
            let rest = String(chars[i...])
            if let m = rest.range(of: #"^\[([^\]]+)\]\(([^)\s]+)[^)]*\)"#, options: .regularExpression) {
                let matched = String(rest[m])
                if let tr = matched.range(of: #"\[([^\]]+)\]"#, options: .regularExpression),
                   let ur = matched.range(of: #"\(([^)\s]+)"#, options: .regularExpression) {
                    let text = matched[tr].dropFirst().dropLast()
                    let url = matched[ur].dropFirst()
                    emit(String(text), base, .linkColor, link: String(url))
                    i += matched.count; continue
                }
            }
        }
        emit(String(c), base, color)
        i += 1
    }
    return out
}

func renderGitHubMarkdown(_ md: String) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let body = NSColor.labelColor
    let size: CGFloat = 13.5
    func para(_ spacing: CGFloat, before: CGFloat = 0, lead: CGFloat = 0, ls: CGFloat = 4) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = spacing; p.paragraphSpacingBefore = before
        p.firstLineHeadIndent = lead; p.headIndent = lead; p.lineSpacing = ls
        return p
    }
    func line(_ attr: NSAttributedString, _ style: NSParagraphStyle) {
        let m = NSMutableAttributedString(attributedString: attr)
        m.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: m.length))
        out.append(m); out.append(NSAttributedString(string: "\n"))
    }
    let lines = md.components(separatedBy: "\n")
    var i = 0
    while i < lines.count {
        let t = lines[i].trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("```") {
            var code = ""; i += 1
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code += lines[i] + "\n"; i += 1 }
            i += 1
            let m = NSMutableAttributedString(string: code.hasSuffix("\n") ? String(code.dropLast()) : code,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                             .foregroundColor: NSColor.labelColor,
                             .backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.10),
                             .paragraphStyle: para(10, before: 6, lead: 12)])
            out.append(m); out.append(NSAttributedString(string: "\n")); continue
        }
        if t.isEmpty { out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 5)])); i += 1; continue }
        if t == "---" || t == "***" || t == "___" {
            line(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 4)]), para(8, before: 6)); i += 1; continue
        }
        if t.hasPrefix("#### ") { line(mdInline(String(t.dropFirst(5)), base: .systemFont(ofSize: 13.5, weight: .semibold), color: body), para(6, before: 12)); i += 1; continue }
        if t.hasPrefix("### ")  { line(mdInline(String(t.dropFirst(4)), base: .systemFont(ofSize: 15, weight: .semibold), color: body), para(6, before: 14)); i += 1; continue }
        if t.hasPrefix("## ")   { line(mdInline(String(t.dropFirst(3)), base: .systemFont(ofSize: 18, weight: .bold), color: body), para(8, before: 18)); i += 1; continue }
        if t.hasPrefix("# ")    { line(mdInline(String(t.dropFirst(2)), base: .systemFont(ofSize: 22, weight: .bold), color: body), para(8, before: 18)); i += 1; continue }
        if t.hasPrefix("> ") || t == ">" {
            line(mdInline(String(t.dropFirst(t.hasPrefix("> ") ? 2 : 1)), base: .systemFont(ofSize: size), color: .secondaryLabelColor), para(6, lead: 14)); i += 1; continue
        }
        if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
            let row = NSMutableAttributedString(string: "•  ", attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.secondaryLabelColor])
            row.append(mdInline(String(t.dropFirst(2)), base: .systemFont(ofSize: size), color: body))
            line(row, para(4, lead: 16)); i += 1; continue
        }
        if let m = t.range(of: #"^\d+\.\s"#, options: .regularExpression) {
            let row = NSMutableAttributedString(string: String(t[m]), attributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
            row.append(mdInline(String(t[m.upperBound...]), base: .systemFont(ofSize: size), color: body))
            line(row, para(4, lead: 18)); i += 1; continue
        }
        line(mdInline(t, base: .systemFont(ofSize: size), color: body), para(9, ls: 4.5)); i += 1
    }
    return out
}

// MARK: - Detail screen (two-column: GitHub-style SKILL.md + sticky sidebar, avatar header)

final class SkillDetailView: NSView {
    var onBack: (() -> Void)?
    var onCopy: ((Skill) -> Void)?
    var onToggleFavorite: ((Skill) -> Void)?
    var onOrganize: ((Skill, NSView) -> Void)?
    private var skill: Skill?
    private var artToken = 0

    private let backBar = NSView()
    private let topDivider = NSBox()
    private var backBarHeight: NSLayoutConstraint!

    private let banner = SkillArtView()
    private let bannerName = NSTextField(labelWithString: "")
    private let bannerPillBox = NSView()
    private let bannerPillLabel = NSTextField(labelWithString: "")
    private let bannerStatus = NSTextField(labelWithString: "")

    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let sidebarStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setShowsBackBar(_ show: Bool) {
        backBar.isHidden = !show
        topDivider.isHidden = !show
        backBarHeight.constant = show ? 40 : 0
    }

    private func build() {
        backBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backBar)
        let back = NSButton(title: "All skills", target: self, action: #selector(backTapped))
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        back.imagePosition = .imageLeading
        back.bezelStyle = .recessed; back.isBordered = false
        back.contentTintColor = .controlAccentColor
        back.font = skelfFont(.callout, .medium)
        back.translatesAutoresizingMaskIntoConstraints = false
        backBar.addSubview(back)
        topDivider.boxType = .separator
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topDivider)

        banner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(banner)
        bannerName.font = .systemFont(ofSize: 24, weight: .bold)
        bannerName.textColor = .white
        bannerName.lineBreakMode = .byTruncatingTail
        bannerName.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(bannerName)
        bannerPillBox.wantsLayer = true
        bannerPillBox.layer?.cornerRadius = 11
        bannerPillBox.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        bannerPillBox.translatesAutoresizingMaskIntoConstraints = false
        bannerPillLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        bannerPillLabel.textColor = .white
        bannerPillLabel.translatesAutoresizingMaskIntoConstraints = false
        bannerPillBox.addSubview(bannerPillLabel)
        banner.addSubview(bannerPillBox)
        bannerStatus.font = .systemFont(ofSize: 12, weight: .semibold)
        bannerStatus.textColor = NSColor.white.withAlphaComponent(0.9)
        bannerStatus.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(bannerStatus)

        let bodyRow = NSView()
        bodyRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bodyRow)

        // left: a Summary + the SKILL.md inside a GitHub-style README card (scrolls)
        let leftScroll = NSScrollView()
        leftScroll.translatesAutoresizingMaskIntoConstraints = false
        leftScroll.hasVerticalScroller = true
        leftScroll.drawsBackground = false
        leftScroll.borderType = .noBorder
        bodyRow.addSubview(leftScroll)
        let leftClip = leftScroll.contentView
        let leftDoc = FlippedView()
        leftDoc.translatesAutoresizingMaskIntoConstraints = false
        leftScroll.documentView = leftDoc
        let leftStack = NSStackView()
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 16
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        leftDoc.addSubview(leftStack)

        // Summary block (the description, pinned above the README)
        let summaryHeader = NSTextField(labelWithString: "SUMMARY")
        summaryHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        summaryHeader.textColor = .secondaryLabelColor
        summaryLabel.font = .systemFont(ofSize: 14.5)
        summaryLabel.textColor = .labelColor
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        let summaryBlock = NSStackView(views: [summaryHeader, summaryLabel])
        summaryBlock.orientation = .vertical; summaryBlock.alignment = .leading; summaryBlock.spacing = 6
        summaryBlock.translatesAutoresizingMaskIntoConstraints = false
        leftStack.addArrangedSubview(summaryBlock)

        // GitHub-style README card: bordered, with a file-header bar, then the rendered body
        let readmeCard = NSView()
        readmeCard.wantsLayer = true
        readmeCard.layer?.cornerRadius = 8
        readmeCard.layer?.borderWidth = 1
        readmeCard.layer?.borderColor = NSColor.separatorColor.cgColor
        readmeCard.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        readmeCard.layer?.masksToBounds = true
        readmeCard.translatesAutoresizingMaskIntoConstraints = false
        let hdr = NSView()
        hdr.wantsLayer = true
        hdr.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        hdr.translatesAutoresizingMaskIntoConstraints = false
        let hdrIcon = NSImageView()
        hdrIcon.image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: nil)
        hdrIcon.contentTintColor = .secondaryLabelColor
        hdrIcon.translatesAutoresizingMaskIntoConstraints = false
        let hdrLabel = NSTextField(labelWithString: "SKILL.md")
        hdrLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        hdrLabel.textColor = .labelColor
        hdrLabel.translatesAutoresizingMaskIntoConstraints = false
        let hdrDivider = NSBox(); hdrDivider.boxType = .separator
        hdrDivider.translatesAutoresizingMaskIntoConstraints = false
        hdr.addSubview(hdrIcon); hdr.addSubview(hdrLabel)
        readmeCard.addSubview(hdr); readmeCard.addSubview(hdrDivider)
        bodyLabel.isSelectable = true
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        readmeCard.addSubview(bodyLabel)
        leftStack.addArrangedSubview(readmeCard)

        NSLayoutConstraint.activate([
            leftDoc.topAnchor.constraint(equalTo: leftClip.topAnchor),
            leftDoc.leadingAnchor.constraint(equalTo: leftClip.leadingAnchor),
            leftDoc.trailingAnchor.constraint(equalTo: leftClip.trailingAnchor),
            leftDoc.widthAnchor.constraint(equalTo: leftClip.widthAnchor),
            leftStack.topAnchor.constraint(equalTo: leftDoc.topAnchor, constant: 20),
            leftStack.leadingAnchor.constraint(equalTo: leftDoc.leadingAnchor, constant: 24),
            leftStack.trailingAnchor.constraint(equalTo: leftDoc.trailingAnchor, constant: -22),
            leftStack.bottomAnchor.constraint(equalTo: leftDoc.bottomAnchor, constant: -24),
            summaryBlock.widthAnchor.constraint(equalTo: leftStack.widthAnchor),
            readmeCard.widthAnchor.constraint(equalTo: leftStack.widthAnchor),

            hdr.topAnchor.constraint(equalTo: readmeCard.topAnchor),
            hdr.leadingAnchor.constraint(equalTo: readmeCard.leadingAnchor),
            hdr.trailingAnchor.constraint(equalTo: readmeCard.trailingAnchor),
            hdr.heightAnchor.constraint(equalToConstant: 42),
            hdrIcon.leadingAnchor.constraint(equalTo: hdr.leadingAnchor, constant: 16),
            hdrIcon.centerYAnchor.constraint(equalTo: hdr.centerYAnchor),
            hdrIcon.widthAnchor.constraint(equalToConstant: 15),
            hdrLabel.leadingAnchor.constraint(equalTo: hdrIcon.trailingAnchor, constant: 8),
            hdrLabel.centerYAnchor.constraint(equalTo: hdr.centerYAnchor),
            hdrDivider.topAnchor.constraint(equalTo: hdr.bottomAnchor),
            hdrDivider.leadingAnchor.constraint(equalTo: readmeCard.leadingAnchor),
            hdrDivider.trailingAnchor.constraint(equalTo: readmeCard.trailingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: hdrDivider.bottomAnchor, constant: 18),
            bodyLabel.leadingAnchor.constraint(equalTo: readmeCard.leadingAnchor, constant: 20),
            bodyLabel.trailingAnchor.constraint(equalTo: readmeCard.trailingAnchor, constant: -20),
            bodyLabel.bottomAnchor.constraint(equalTo: readmeCard.bottomAnchor, constant: -22),
        ])

        // right: sticky sidebar (own scroll)
        let sidebarScroll = NSScrollView()
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        sidebarScroll.scrollerStyle = .overlay
        sidebarScroll.drawsBackground = false
        sidebarScroll.borderType = .noBorder
        bodyRow.addSubview(sidebarScroll)
        let sideClip = sidebarScroll.contentView
        let sideDoc = FlippedView()
        sideDoc.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.documentView = sideDoc
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 14
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sideDoc.addSubview(sidebarStack)

        backBarHeight = backBar.heightAnchor.constraint(equalToConstant: 40)
        NSLayoutConstraint.activate([
            backBar.topAnchor.constraint(equalTo: topAnchor),
            backBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            backBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            backBarHeight,
            back.leadingAnchor.constraint(equalTo: backBar.leadingAnchor, constant: 12),
            back.centerYAnchor.constraint(equalTo: backBar.centerYAnchor),
            topDivider.topAnchor.constraint(equalTo: backBar.bottomAnchor),
            topDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: trailingAnchor),

            banner.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            banner.leadingAnchor.constraint(equalTo: leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: trailingAnchor),
            banner.heightAnchor.constraint(equalToConstant: 150),
            bannerName.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 24),
            bannerName.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -18),
            bannerName.trailingAnchor.constraint(lessThanOrEqualTo: bannerPillBox.leadingAnchor, constant: -10),
            bannerPillBox.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -24),
            bannerPillBox.centerYAnchor.constraint(equalTo: bannerName.centerYAnchor),
            bannerPillBox.heightAnchor.constraint(equalToConstant: 24),
            bannerPillLabel.leadingAnchor.constraint(equalTo: bannerPillBox.leadingAnchor, constant: 10),
            bannerPillLabel.trailingAnchor.constraint(equalTo: bannerPillBox.trailingAnchor, constant: -10),
            bannerPillLabel.centerYAnchor.constraint(equalTo: bannerPillBox.centerYAnchor),
            bannerStatus.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 24),
            bannerStatus.bottomAnchor.constraint(equalTo: bannerName.topAnchor, constant: -4),

            bodyRow.topAnchor.constraint(equalTo: banner.bottomAnchor),
            bodyRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            bodyRow.bottomAnchor.constraint(equalTo: bottomAnchor),

            leftScroll.topAnchor.constraint(equalTo: bodyRow.topAnchor),
            leftScroll.leadingAnchor.constraint(equalTo: bodyRow.leadingAnchor),
            leftScroll.bottomAnchor.constraint(equalTo: bodyRow.bottomAnchor),
            leftScroll.trailingAnchor.constraint(equalTo: sidebarScroll.leadingAnchor),

            sidebarScroll.topAnchor.constraint(equalTo: bodyRow.topAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: bodyRow.bottomAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: bodyRow.trailingAnchor),
            sidebarScroll.widthAnchor.constraint(equalToConstant: 300),
            sideDoc.topAnchor.constraint(equalTo: sideClip.topAnchor),
            sideDoc.leadingAnchor.constraint(equalTo: sideClip.leadingAnchor),
            sideDoc.trailingAnchor.constraint(equalTo: sideClip.trailingAnchor),
            sideDoc.widthAnchor.constraint(equalTo: sideClip.widthAnchor),
            sidebarStack.topAnchor.constraint(equalTo: sideDoc.topAnchor, constant: 20),
            sidebarStack.leadingAnchor.constraint(equalTo: sideDoc.leadingAnchor, constant: 4),
            sidebarStack.trailingAnchor.constraint(equalTo: sideDoc.trailingAnchor, constant: -20),
            sidebarStack.bottomAnchor.constraint(lessThanOrEqualTo: sideDoc.bottomAnchor, constant: -24),
        ])
    }

    private func card(_ title: String?, _ content: NSView) -> NSView {
        let c = NSView()
        c.wantsLayer = true
        c.layer?.cornerRadius = 12; c.layer?.borderWidth = 1
        c.layer?.borderColor = NSColor.separatorColor.cgColor
        c.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        c.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let title = title {
            let h = NSTextField(labelWithString: title.uppercased())
            h.font = skelfFont(.caption2, .semibold); h.textColor = .secondaryLabelColor
            stack.addArrangedSubview(h)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(content)
        content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        c.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: c.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -14),
        ])
        return c
    }

    private func metaRow(_ key: String, _ value: String) -> NSView {
        let k = NSTextField(labelWithString: key.uppercased())
        k.font = skelfFont(.caption2, .semibold); k.textColor = .tertiaryLabelColor
        k.translatesAutoresizingMaskIntoConstraints = false
        k.widthAnchor.constraint(equalToConstant: 78).isActive = true
        let v = NSTextField(labelWithString: value)
        v.font = skelfFont(.callout); v.textColor = .labelColor
        v.lineBreakMode = .byTruncatingMiddle; v.isSelectable = true
        v.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [k, v])
        row.orientation = .horizontal; row.alignment = .firstBaseline; row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func sidebarButton(_ title: String, _ symbol: String, _ action: Selector, prominent: Bool = false) -> NSButton {
        let b = NSButton(title: " " + title, target: self, action: action)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.imagePosition = .imageLeading
        b.bezelStyle = .rounded
        b.controlSize = .large
        b.translatesAutoresizingMaskIntoConstraints = false
        if prominent { b.keyEquivalent = "\r" }
        return b
    }

    func configure(_ skill: Skill, isFavorite: Bool) {
        self.skill = skill
        artToken += 1
        let token = artToken
        let creator = skill.source.contains("/") ? skill.source.split(separator: "/").first.map(String.init) : nil
        banner.setGradient(skill.name)
        if let creator = creator {
            if let img = AvatarStore.shared.cached(creator) { banner.setAvatar(img) }
            else { AvatarStore.shared.fetch(creator) { [weak self] img in
                guard let self = self, self.artToken == token, let img = img else { return }
                self.banner.setAvatar(img) } }
        }
        bannerName.stringValue = skill.name
        bannerPillLabel.stringValue = skill.initiator
        bannerStatus.stringValue = skill.enabled ? "● Enabled" : "○ Installed · off"
        bannerStatus.textColor = skill.enabled ? NSColor.systemGreen : NSColor.white.withAlphaComponent(0.8)

        // left column: Summary + the GitHub-style SKILL.md card
        let raw = (try? String(contentsOfFile: skill.skillMDPath, encoding: .utf8)) ?? ""
        let (_, body) = splitFrontmatter(raw)
        summaryLabel.stringValue = skill.description.isEmpty ? "No description in SKILL.md." : skill.description
        let bodyTrim = body.trimmingCharacters(in: .whitespacesAndNewlines)
        bodyLabel.attributedStringValue = bodyTrim.isEmpty
            ? NSAttributedString(string: "This skill's SKILL.md has no content beyond its frontmatter.",
                                 attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
            : renderGitHubMarkdown(bodyTrim)

        rebuildSidebar(skill, isFavorite: isFavorite, creator: creator, token: token)
    }

    private func rebuildSidebar(_ skill: Skill, isFavorite: Bool, creator: String?, token: Int) {
        sidebarStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let creatorName = creator ?? "Local"

        // Source card (avatar + repo + View on GitHub)
        let avatar = SkillArtView(); avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.layer?.cornerRadius = 8; avatar.showScrim = false
        avatar.setGradient(creatorName)
        if let creator = creator {
            if let img = AvatarStore.shared.cached(creator) { avatar.setAvatar(img) }
            else { AvatarStore.shared.fetch(creator) { [weak self] img in
                guard let self = self, self.artToken == token, let img = img else { return }
                avatar.setAvatar(img) } }
        }
        avatar.widthAnchor.constraint(equalToConstant: 36).isActive = true
        avatar.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let cName = NSTextField(labelWithString: creatorName); cName.font = skelfFont(.callout, .semibold)
        let repo = NSTextField(labelWithString: skill.source); repo.font = skelfFont(.caption1)
        repo.textColor = .secondaryLabelColor; repo.lineBreakMode = .byTruncatingMiddle
        let nameCol = NSStackView(views: [cName, repo])
        nameCol.orientation = .vertical; nameCol.alignment = .leading; nameCol.spacing = 1
        let idRow = NSStackView(views: [avatar, nameCol])
        idRow.orientation = .horizontal; idRow.alignment = .centerY; idRow.spacing = 10
        idRow.translatesAutoresizingMaskIntoConstraints = false
        let ghBtn = sidebarButton("View Skill on GitHub", "arrow.up.right.square", #selector(githubTapped))
        ghBtn.isEnabled = skill.skillGithubURL != nil
        let crBtn = sidebarButton("Creator's GitHub", "person.crop.circle", #selector(creatorTapped))
        crBtn.isEnabled = skill.creatorGithubURL != nil
        let srcStack = NSStackView(views: [idRow, ghBtn, crBtn])
        srcStack.orientation = .vertical; srcStack.alignment = .leading; srcStack.spacing = 8
        srcStack.translatesAutoresizingMaskIntoConstraints = false
        addCard(card("Source", srcStack))
        idRow.widthAnchor.constraint(equalTo: srcStack.widthAnchor).isActive = true
        for b in [ghBtn, crBtn] { b.widthAnchor.constraint(equalTo: srcStack.widthAnchor).isActive = true }

        // Slash command card (Copy only)
        let copyBtn = sidebarButton("Copy  \(skill.initiator)", "doc.on.clipboard", #selector(copySlashTapped), prominent: true)
        let cmdStack = NSStackView(views: [copyBtn])
        cmdStack.orientation = .vertical; cmdStack.alignment = .leading; cmdStack.spacing = 8
        cmdStack.translatesAutoresizingMaskIntoConstraints = false
        addCard(card("Slash command", cmdStack))
        copyBtn.widthAnchor.constraint(equalTo: cmdStack.widthAnchor).isActive = true

        // Details
        let meta = NSStackView()
        meta.orientation = .vertical; meta.alignment = .leading; meta.spacing = 7
        meta.translatesAutoresizingMaskIntoConstraints = false
        meta.addArrangedSubview(metaRow("Status", skill.enabled ? "Enabled" : "Installed · off"))
        meta.addArrangedSubview(metaRow("Version", skill.version ?? "unversioned"))
        meta.addArrangedSubview(metaRow("Category", skill.category))
        meta.addArrangedSubview(metaRow("Files", "\(skill.fileCount)"))
        meta.addArrangedSubview(metaRow("Installed", skill.installedAt))
        addCard(card("Details", meta))

        // Actions
        let favBtn = sidebarButton(isFavorite ? "Favorited" : "Favorite", isFavorite ? "star.fill" : "star", #selector(favoriteTapped))
        favBtn.contentTintColor = isFavorite ? .systemYellow : nil
        favButtonRef = favBtn
        let folderBtn = sidebarButton("Add to Folder…", "folder.badge.plus", #selector(organizeTapped))
        let actStack = NSStackView(views: [favBtn, folderBtn])
        actStack.orientation = .vertical; actStack.alignment = .leading; actStack.spacing = 8
        actStack.translatesAutoresizingMaskIntoConstraints = false
        addCard(card(nil, actStack))
        for b in [favBtn, folderBtn] { b.widthAnchor.constraint(equalTo: actStack.widthAnchor).isActive = true }
    }

    private weak var favButtonRef: NSButton?
    /// Light favorite-state update (no full reconfigure) for the sidebar button.
    func setFavorite(_ on: Bool) {
        favButtonRef?.title = on ? " Favorited" : " Favorite"
        favButtonRef?.image = NSImage(systemSymbolName: on ? "star.fill" : "star", accessibilityDescription: nil)
        favButtonRef?.contentTintColor = on ? .systemYellow : nil
    }

    private func addCard(_ c: NSView) {
        sidebarStack.addArrangedSubview(c)
        c.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true
    }

    @objc private func backTapped() { onBack?() }
    @objc private func favoriteTapped() { if let s = skill { onToggleFavorite?(s) } }
    @objc private func organizeTapped() { if let s = skill { onOrganize?(s, sidebarStack) } }
    @objc private func copySlashTapped() { if let s = skill { onCopy?(s) } }
    @objc private func githubTapped() {
        guard let url = skill?.skillGithubURL else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func creatorTapped() {
        guard let url = skill?.creatorGithubURL else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Window content (AppKit grid hosted inside a SwiftUI Liquid Glass nav)

// A closure-backed menu item — build folder pickers without @objc plumbing.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

// A menu mirroring the folder tree; `pick` fires with the chosen folder id.
func folderPickerMenu(_ folders: FolderStore, exclude: String? = nil, pick: @escaping (String) -> Void) -> NSMenu {
    let menu = NSMenu()
    func add(_ id: String, _ depth: Int) {
        guard let node = folders.node(id), id != exclude else { return }
        let title = String(repeating: "    ", count: depth) + (id == folders.rootId ? "All Skills" : node.name)
        menu.addItem(ClosureMenuItem(title: title) { pick(id) })
        for c in node.folders { add(c, depth + 1) }
    }
    add(folders.rootId, 0)
    return menu
}

// Modal text prompt (new / rename folder).
func promptForText(title: String, default def: String, _ done: @escaping (String) -> Void) {
    let alert = NSAlert()
    alert.messageText = title
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    tf.stringValue = def
    alert.accessoryView = tf
    alert.window.initialFirstResponder = tf
    if alert.runModal() == .alertFirstButtonReturn {
        let v = tf.stringValue.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty { done(v) }
    }
}

// A collection view that tells a click apart from a drag: it only "activates" an
// item on a clean mouse-up with no drag, so press-and-drag is free to reorder/move.
final class GridCollectionView: NSCollectionView {
    var onActivate: ((IndexPath) -> Void)?
    private var downIP: IndexPath?
    private var downPoint: NSPoint = .zero
    private var didDrag = false

    // NSCollectionView.mouseDown is NOT modal (unlike NSTableView): it returns
    // promptly and drags are driven by later mouseDragged events. So we track the
    // gesture ourselves — navigate only on a clean mouse-up with no drag, which
    // leaves the built-in reorder/move drag path free (see ClickableRow for the
    // same idiom).
    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        downIP = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        didDrag = false
        super.mouseDown(with: event)
    }
    override func mouseDragged(with event: NSEvent) {
        if !didDrag {
            let p = event.locationInWindow
            if hypot(p.x - downPoint.x, p.y - downPoint.y) > 4 { didDrag = true }
        }
        super.mouseDragged(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        let ip = downIP, dragged = didDrag
        super.mouseUp(with: event)
        if let ip = ip, !dragged, event.clickCount == 1 { onActivate?(ip) }
        downIP = nil
        didDrag = false
    }
}

// Lays cards out in a fixed number of columns (4), each a PORTRAIT rectangle (height
// derived from width by the original 300:224 ratio). Card width = viewport/columns, so
// the cards shrink/grow with the window — recomputed live (shouldInvalidateLayout on
// width change) so they adapt instantly.
// A fully custom grid layout. We DON'T subclass NSCollectionViewFlowLayout because, when
// hosted inside a SwiftUI NavigationStack, the flow layout derives its column count from a
// stale (tiny) measurement width and never recovers it — even a fresh instance at the real
// 920pt width still wrapped after 2 columns. This layout positions every item/header frame
// itself from the live clip width, so the column count truly flows with the window.
final class CardFlowLayout: NSCollectionViewLayout {
    static let aspect: CGFloat = 300.0 / 224.0   // height / width — portrait
    // The column count is NOT fixed: it flows with the window. We aim each card at
    // ~targetWidth, fit as many whole columns as the available width allows (never below
    // minWidth), then share the slack so the row fills evenly. Cards stay portrait.
    static let targetWidth: CGFloat = 210
    static let minWidth: CGFloat = 150
    let interitem: CGFloat = 14
    let lineSpacing: CGFloat = 16
    let inset = NSEdgeInsets(top: 4, left: 18, bottom: 16, right: 18)
    let headerHeight: CGFloat = 30

    private var itemAttrs: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var headerAttrs: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var contentSize: NSSize = .zero
    private var lastWidth: CGFloat = 0

    private func layoutWidth(_ cv: NSCollectionView) -> CGFloat {
        // The scroll view's visible (clip) width is the true width; the documentView's own
        // bounds is content-driven and unreliable here.
        cv.enclosingScrollView?.contentView.bounds.width ?? cv.bounds.width
    }

    override func prepare() {
        super.prepare()
        itemAttrs.removeAll(keepingCapacity: true)
        headerAttrs.removeAll(keepingCapacity: true)
        guard let cv = collectionView else { contentSize = .zero; return }
        let width = layoutWidth(cv)
        lastWidth = width
        guard width > 1 else { contentSize = NSSize(width: max(width, 1), height: 0); return }

        let avail = width - inset.left - inset.right
        var cols = max(1, floor((avail + interitem) / (CardFlowLayout.targetWidth + interitem)))
        while cols > 1 && floor((avail - (cols - 1) * interitem) / cols) < CardFlowLayout.minWidth { cols -= 1 }
        let colsI = max(1, Int(cols))
        let itemW = floor((avail - CGFloat(colsI - 1) * interitem) / CGFloat(colsI))
        let itemH = floor(itemW * CardFlowLayout.aspect)

        var y: CGFloat = 0
        for s in 0..<cv.numberOfSections {
            let count = cv.numberOfItems(inSection: s)
            let hip = IndexPath(item: 0, section: s)
            let h = NSCollectionViewLayoutAttributes(forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, with: hip)
            h.frame = NSRect(x: 0, y: y, width: width, height: headerHeight)
            headerAttrs[hip] = h
            y += headerHeight + inset.top

            for i in 0..<count {
                let row = i / colsI, col = i % colsI
                let x = inset.left + CGFloat(col) * (itemW + interitem)
                let iy = y + CGFloat(row) * (itemH + lineSpacing)
                let ip = IndexPath(item: i, section: s)
                let a = NSCollectionViewLayoutAttributes(forItemWith: ip)
                a.frame = NSRect(x: x, y: iy, width: itemW, height: itemH)
                itemAttrs[ip] = a
            }
            let rows = count == 0 ? 0 : (count + colsI - 1) / colsI
            if rows > 0 { y += CGFloat(rows) * itemH + CGFloat(rows - 1) * lineSpacing }
            y += inset.bottom
        }
        contentSize = NSSize(width: width, height: y)
    }

    override var collectionViewContentSize: NSSize { contentSize }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        var out: [NSCollectionViewLayoutAttributes] = []
        for (_, a) in headerAttrs where a.frame.intersects(rect) { out.append(a) }
        for (_, a) in itemAttrs where a.frame.intersects(rect) { out.append(a) }
        return out
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        itemAttrs[indexPath]
    }
    override func layoutAttributesForSupplementaryView(ofKind elementKind: NSCollectionView.SupplementaryElementKind,
                                                       at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        elementKind == NSCollectionView.elementKindSectionHeader ? headerAttrs[indexPath] : nil
    }

    // Drag/drop needs the layout to translate the cursor into a drop position. The bare
    // NSCollectionViewLayout base returns nil for both of these — which is why drop-on-folder
    // AND reorder broke the moment we stopped subclassing NSCollectionViewFlowLayout (it
    // synthesized them for free). Re-supply them from our cached item/header frames.

    // Translate the hover point into a drop target. The returned attribute's CATEGORY is
    // the decision: an ITEM attribute proposes a drop ONTO that item (.on — e.g. file a
    // skill into a folder), an INTER-ITEM-GAP attribute proposes an insertion (.before —
    // i.e. reorder). So we must return a gap for most of the surface and an item only over
    // its centre — otherwise every drop is an ".on" and reorder can never happen (which is
    // exactly what was broken: folders nested into whatever was adjacent, nothing reordered).
    override func layoutAttributesForDropTarget(at point: NSPoint) -> NSCollectionViewLayoutAttributes? {
        // Over an item: centre third → drop ONTO it; left/right thirds → reorder gap.
        for (ip, a) in itemAttrs where a.frame.contains(point) {
            let f = a.frame
            let edge = f.width * 0.34
            if point.x <= f.minX + edge { return layoutAttributesForInterItemGap(before: ip) }
            if point.x >= f.maxX - edge { return layoutAttributesForInterItemGap(before: IndexPath(item: ip.item + 1, section: ip.section)) }
            return a
        }
        // Between items / margins: snap to the nearest reorder gap (insert before or after
        // the nearest item depending on which side of its centre we're on).
        var bestIP: IndexPath?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (ip, a) in itemAttrs {
            let d = hypot(a.frame.midX - point.x, a.frame.midY - point.y)
            if d < bestDist { bestDist = d; bestIP = ip }
        }
        guard let ip = bestIP, let f = itemAttrs[ip]?.frame else { return nil }
        return layoutAttributesForInterItemGap(before: point.x > f.midX ? IndexPath(item: ip.item + 1, section: ip.section) : ip)
    }

    // Drop BETWEEN items (reorder): a thin gap attribute at the leading edge of the item
    // BEFORE which the dragged item would be inserted. Without it AppKit can't offer a
    // `.before` drop position, so reordering did nothing.
    override func layoutAttributesForInterItemGap(before indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        let gap = NSCollectionViewLayoutAttributes(forInterItemGapBefore: indexPath)
        if let a = itemAttrs[indexPath] {
            // Gap sits just to the LEFT of the target item.
            gap.frame = NSRect(x: a.frame.minX - interitem, y: a.frame.minY, width: interitem, height: a.frame.height)
        } else if indexPath.item > 0,
                  let prev = itemAttrs[IndexPath(item: indexPath.item - 1, section: indexPath.section)] {
            // "Before the end" of a section: gap sits just to the RIGHT of the last item.
            gap.frame = NSRect(x: prev.frame.maxX, y: prev.frame.minY, width: interitem, height: prev.frame.height)
        } else if let h = headerAttrs[IndexPath(item: 0, section: indexPath.section)] {
            // Empty section: park the gap just under its header so the gesture never stalls.
            gap.frame = NSRect(x: inset.left, y: h.frame.maxY, width: interitem, height: 1)
        }
        return gap
    }

    // Re-lay-out only when the visible width changes (not on vertical scroll).
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let cv = collectionView else { return false }
        return abs(layoutWidth(cv) - lastWidth) > 0.5
    }
}

// A section header ("Folders" / "Skills" / "Off Skills") above each grid group.
final class SectionHeaderView: NSView {
    static let id = NSUserInterfaceItemIdentifier("SectionHeader")
    let label = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// The grid for ONE folder. Navigation + toolbar live in SwiftUI; this renders the
// folder's entries in 3 sections (Folders / Skills / Off Skills), handles
// drag/drop/reorder + per-tile menus, and reports clicks.
final class GridViewController: NSViewController, NSCollectionViewDataSource,
                                NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
    let model: SkelfModel
    var folderId: String
    var onOpenSkill: ((String) -> Void)?
    var onOpenFolder: ((String) -> Void)?

    private var sections: [(title: String, items: [GridEntry])] = []
    private var query = ""
    private var lastToken = -1

    private let collectionView = GridCollectionView()
    private let gridScroll = NSScrollView()
    private let skillItemID = NSUserInterfaceItemIdentifier("SkillGridItem")
    private let folderItemID = NSUserInterfaceItemIdentifier("FolderGridItem")

    init(model: SkelfModel, folderId: String) {
        self.model = model
        self.folderId = folderId
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
        gridScroll.translatesAutoresizingMaskIntoConstraints = false
        gridScroll.hasVerticalScroller = true
        gridScroll.borderType = .noBorder
        gridScroll.drawsBackground = false
        root.addSubview(gridScroll)

        collectionView.collectionViewLayout = CardFlowLayout()
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(SkillGridItem.self, forItemWithIdentifier: skillItemID)
        collectionView.register(FolderGridItem.self, forItemWithIdentifier: folderItemID)
        collectionView.register(SectionHeaderView.self,
                                forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: SectionHeaderView.id)
        collectionView.registerForDraggedTypes([skelfEntryType])
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)
        collectionView.onActivate = { [weak self] ip in self?.activate(ip) }
        gridScroll.documentView = collectionView

        NSLayoutConstraint.activate([
            gridScroll.topAnchor.constraint(equalTo: root.topAnchor),
            gridScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            gridScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            gridScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() { super.viewDidLoad(); reload() }

    // Cards are portrait and the column count flows with the window width. CardFlowLayout
    // computes item frames from the live clip width, so re-invalidate when that changes
    // (the SwiftUI host's initial tiny measurement pass means the first layout can land at
    // the wrong width otherwise).
    private var lastViewportW: CGFloat = 0
    override func viewDidLayout() {
        super.viewDidLayout()
        let w = gridScroll.contentView.bounds.width
        if abs(w - lastViewportW) > 0.5 {
            lastViewportW = w
            collectionView.collectionViewLayout?.invalidateLayout()
        }
    }

    /// Called by the SwiftUI host whenever search / data changes. (CardFlowLayout
    /// handles responsive resizing itself, live, via shouldInvalidateLayout.)
    func apply(query: String, filter: Int, token: Int) {
        guard query != self.query || token != lastToken else { return }
        self.query = query; lastToken = token
        if isViewLoaded { reload() }
    }

    func reload() { buildEntries(); collectionView.reloadData() }

    /// Update only the favorite stars on visible cards — no reorder, no reload (so the
    /// card that was just tapped keeps its in-place pop animation).
    func refreshFavorites() {
        guard isViewLoaded else { return }
        for case let item as SkillGridItem in collectionView.visibleItems() {
            item.setFavorite(model.favorites.isFavorite(item.skillId), animated: false)
        }
    }

    private func skillMatches(_ s: Skill, _ q: String) -> Bool {
        q.isEmpty || s.name.lowercased().contains(q) || s.description.lowercased().contains(q)
            || s.category.lowercased().contains(q) || s.source.lowercased().contains(q)
    }
    private func skillVerified(_ s: Skill) -> Bool {
        guard let u = s.skillGithubURL?.absoluteString else { return false }
        return GitHubVerifier.shared.status(u) == true
    }

    private func buildEntries() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let folders = model.folders.childFolders(of: folderId).filter { q.isEmpty || $0.name.lowercased().contains(q) }
        let here = model.folders.skillIds(in: folderId).compactMap { id in model.store.skills.first { $0.id == id } }
        let skills = here.filter { $0.enabled && skillMatches($0, q) }     // stored order; favoriting never reorders
        let off = here.filter { !$0.enabled && skillMatches($0, q) }
        var s: [(title: String, items: [GridEntry])] = []
        if !folders.isEmpty { s.append(("Folders", folders.map { .folder($0) })) }
        if !skills.isEmpty { s.append(("Skills", skills.map { .skill($0) })) }
        if !off.isEmpty { s.append(("Off Skills", off.map { .skill($0) })) }
        sections = s
    }

    private func entry(at ip: IndexPath) -> GridEntry? {
        guard ip.section < sections.count, ip.item < sections[ip.section].items.count else { return nil }
        return sections[ip.section].items[ip.item]
    }

    private func activate(_ ip: IndexPath) {
        switch entry(at: ip) {
        case .folder(let n): (collectionView.item(at: ip) as? FolderGridItem)?.pressPop(); onOpenFolder?(n.id)
        case .skill(let s): (collectionView.item(at: ip) as? SkillGridItem)?.pressPop(); onOpenSkill?(s.id)
        case .none: break
        }
        collectionView.deselectAll(nil)
    }

    // --- collection data ---
    func numberOfSections(in cv: NSCollectionView) -> Int { sections.count }
    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        section < sections.count ? sections[section].items.count : 0
    }

    func collectionView(_ cv: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let v = cv.makeSupplementaryView(ofKind: kind, withIdentifier: SectionHeaderView.id, for: indexPath)
        if let h = v as? SectionHeaderView, indexPath.section < sections.count {
            h.label.stringValue = sections[indexPath.section].title.uppercased()
        }
        return v
    }
    func collectionView(_ cv: NSCollectionView, layout: NSCollectionViewLayout,
                        referenceSizeForHeaderInSection section: Int) -> NSSize {
        NSSize(width: cv.bounds.width, height: 30)
    }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        switch entry(at: indexPath) {
        case .folder(let node):
            let item = cv.makeItem(withIdentifier: folderItemID, for: indexPath)
            if let folder = item as? FolderGridItem {
                folder.configure(node, inMenuBar: model.folders.showsInMenuBar(node.id))
                folder.onMenu = { [weak self] anchor in
                    guard let self = self else { return }
                    self.popMenu(self.folderMenu(node), at: anchor)
                }
            }
            item.view.menu = folderMenu(node)
            return item
        case .skill(let skill):
            let item = cv.makeItem(withIdentifier: skillItemID, for: indexPath)
            if let grid = item as? SkillGridItem {
                grid.configure(skill, isFavorite: model.favorites.isFavorite(skill.id), verified: skillVerified(skill))
                grid.onToggleFavorite = { [weak self] in self?.model.favorites.toggle(skill.id) }
                grid.onCopy = { [weak self] in self?.model.copySkill(skill) }
                grid.onMenu = { [weak self] anchor in
                    guard let self = self else { return }
                    self.popMenu(self.skillMenu(skill), at: anchor)
                }
            }
            item.view.menu = skillMenu(skill)
            return item
        case .none:
            return cv.makeItem(withIdentifier: skillItemID, for: indexPath)
        }
    }

    private func popMenu(_ menu: NSMenu, at anchor: NSView) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 2), in: anchor)
    }

    // --- drag & drop / reorder ---
    func collectionView(_ cv: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        return query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard let e = entry(at: indexPath) else { return nil }
        let item = NSPasteboardItem()
        switch e {
        case .folder(let n): item.setString("folder:\(n.id)", forType: skelfEntryType)
        case .skill(let s): item.setString("skill:\(s.id)", forType: skelfEntryType)
        }
        return item
    }

    func collectionView(_ cv: NSCollectionView,
                        validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let idx = proposedDropIndexPath.pointee as IndexPath
        let draggingFolder = (draggingInfo.draggingPasteboard.pasteboardItems?.first?
            .string(forType: skelfEntryType)?.hasPrefix("folder:")) ?? false
        if proposedDropOperation.pointee == .on {
            // Keep ".on" ONLY for a skill dropped onto a folder (file it in). A folder
            // dropped onto a folder, or anything onto a skill, becomes a reorder — so
            // folders never nest by accident and a centre-drop still reorders.
            if case .folder = entry(at: idx), !draggingFolder { return .move }
            proposedDropOperation.pointee = .before
        }
        // Reorder (.before) is only meaningful WITHIN the matching kind. Reject a skill
        // dropped at a folder gap (or a folder at a skill gap) so it can't silently jump to
        // the end of its own list — the drop indicator then only shows where it makes sense.
        switch entry(at: idx) {
        case .folder where !draggingFolder: return []
        case .skill where draggingFolder: return []
        default: break   // matching kind, or .none (end-of-section gap) → allow
        }
        return .move
    }

    func collectionView(_ cv: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let pbItem = draggingInfo.draggingPasteboard.pasteboardItems?.first,
              let str = pbItem.string(forType: skelfEntryType) else { return false }
        let comps = str.split(separator: ":", maxSplits: 1).map(String.init)
        guard comps.count == 2 else { return false }
        let isFolder = comps[0] == "folder"
        let draggedId = comps[1]

        if dropOperation == .on, case .folder(let target) = entry(at: indexPath) {
            if isFolder { model.folders.moveFolder(draggedId, to: target.id) }
            else { model.folders.moveSkill(draggedId, from: folderId, to: target.id) }
            Sound.play(.move)
            return true
        }
        let anchor = anchorId(forKind: isFolder, at: indexPath)
        if isFolder { model.folders.reorderFolder(draggedId, in: folderId, before: anchor) }
        else { model.folders.reorderSkill(draggedId, in: folderId, before: anchor) }
        Sound.play(.move)
        return true
    }

    private func anchorId(forKind isFolder: Bool, at ip: IndexPath) -> String? {
        switch entry(at: ip) {
        case .folder(let n): return isFolder ? n.id : nil
        case .skill(let s): return isFolder ? nil : s.id
        case .none: return nil
        }
    }

    // --- per-tile context menus ---
    private func simpleItem(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, handler: handler)
    }

    private func skillMenu(_ skill: Skill) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(simpleItem("Open") { [weak self] in self?.onOpenSkill?(skill.id) })
        menu.addItem(simpleItem("Copy Slash Command") { [weak self] in self?.model.copySkill(skill) })
        menu.addItem(.separator())
        let fav = model.favorites.isFavorite(skill.id)
        menu.addItem(simpleItem(fav ? "Unfavorite" : "Favorite") { [weak self] in self?.model.favorites.toggle(skill.id) })
        menu.addItem(.separator())
        let moveItem = NSMenuItem(title: "Move to Folder", action: nil, keyEquivalent: "")
        moveItem.submenu = folderPickerMenu(model.folders) { [weak self] target in
            guard let self = self else { return }
            self.model.folders.moveSkill(skill.id, from: self.folderId, to: target); Sound.play(.move)
        }
        menu.addItem(moveItem)
        let copyItem = NSMenuItem(title: "Copy to Folder", action: nil, keyEquivalent: "")
        copyItem.submenu = folderPickerMenu(model.folders) { [weak self] target in
            self?.model.folders.copySkill(skill.id, to: target); Sound.play(.move)
        }
        menu.addItem(copyItem)
        menu.addItem(.separator())
        menu.addItem(simpleItem("Cut") { [weak self] in self?.setSkillClip(skill, cut: true) })
        menu.addItem(simpleItem("Copy") { [weak self] in self?.setSkillClip(skill, cut: false) })
        if folderId != model.folders.rootId {
            menu.addItem(.separator())
            menu.addItem(simpleItem("Remove from “\(model.folderName(folderId))”") { [weak self] in
                guard let self = self else { return }
                self.model.folders.moveSkill(skill.id, from: self.folderId, to: self.model.folders.rootId)
            })
        }
        return menu
    }

    private func folderMenu(_ node: FolderStore.Node) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(simpleItem("Open") { [weak self] in self?.onOpenFolder?(node.id) })
        menu.addItem(simpleItem("Rename…") { [weak self] in
            promptForText(title: "Rename folder", default: node.name) { self?.model.folders.rename(node.id, to: $0) }
        })
        menu.addItem(simpleItem("New Folder Inside…") { [weak self] in
            promptForText(title: "New folder name", default: "New Folder") { self?.model.folders.createFolder(name: $0, in: node.id) }
        })
        menu.addItem(.separator())
        let inBar = model.folders.showsInMenuBar(node.id)
        let barItem = simpleItem(inBar ? "Remove from Menu Bar" : "Add to Menu Bar") { [weak self] in
            self?.model.folders.setShowInMenuBar(node.id, !inBar)
        }
        if inBar { barItem.state = .on }
        menu.addItem(barItem)
        menu.addItem(.separator())
        menu.addItem(simpleItem("Cut") { [weak self] in self?.setFolderClip(node) })
        menu.addItem(.separator())
        menu.addItem(simpleItem("Delete Folder") { [weak self] in self?.confirmDeleteFolder(node) })
        return menu
    }

    private func setSkillClip(_ skill: Skill, cut: Bool) {
        model.clip = SkelfModel.Clip(id: skill.id, isFolder: false, cut: cut, source: folderId, name: skill.name)
    }
    private func setFolderClip(_ node: FolderStore.Node) {
        model.clip = SkelfModel.Clip(id: node.id, isFolder: true, cut: true, source: node.parent ?? model.folders.rootId, name: node.name)
    }

    private func confirmDeleteFolder(_ n: FolderStore.Node) {
        let count = n.folders.count + n.skills.count
        if count > 0 {
            let a = NSAlert()
            a.messageText = "Delete “\(n.name)”?"
            a.informativeText = "Its \(count) item\(count == 1 ? "" : "s") move back to the parent. Your skills aren't uninstalled — this only changes how they're organized here."
            a.addButton(withTitle: "Delete Folder")
            a.addButton(withTitle: "Cancel")
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        model.folders.deleteFolder(n.id)
    }
}

// MARK: - SwiftUI navigation shell (Liquid Glass navigation + toolbars, macOS 26)

enum Route: Hashable {
    case folder(String)
    case skill(String)
}

@Observable
final class SkelfModel {
    @ObservationIgnored let store: SkillStore
    @ObservationIgnored let favorites: Favorites
    @ObservationIgnored let folders: FolderStore
    @ObservationIgnored let copySkill: (Skill) -> Void

    var path: [Route] = []
    var reloadToken = 0
    var favoritesToken = 0      // bumped on favorite changes only (no destructive grid reload)

    struct Clip { let id: String; let isFolder: Bool; let cut: Bool; let source: String; let name: String }
    var clip: Clip?

    init(store: SkillStore, favorites: Favorites, folders: FolderStore, copySkill: @escaping (Skill) -> Void) {
        self.store = store
        self.favorites = favorites
        self.folders = folders
        self.copySkill = copySkill
    }

    func bumpReload() { reloadToken &+= 1 }
    func bumpFavorites() { favoritesToken &+= 1 }
    func skill(_ id: String) -> Skill? { store.skills.first { $0.id == id } }
    func folderName(_ id: String) -> String { folders.node(id)?.name ?? "Folder" }

    func openSkill(_ id: String) { if skill(id) != nil { path = [.skill(id)] } }
    func enterFolder(_ id: String) {
        guard folders.node(id) != nil else { return }
        path = folders.path(to: id).map { $0.id }.filter { $0 != folders.rootId }.map { Route.folder($0) }
    }

    func newFolder(in parent: String) {
        promptForText(title: "New folder name", default: "New Folder") { [weak self] name in
            self?.folders.createFolder(name: name, in: parent)
        }
    }

    func pasteInto(_ folderId: String) {
        guard let c = clip else { return }
        if c.isFolder { folders.moveFolder(c.id, to: folderId); clip = nil }
        else if c.cut { folders.moveSkill(c.id, from: c.source, to: folderId); clip = nil }
        else { folders.copySkill(c.id, to: folderId) }   // keep clip for multi-paste
        Sound.play(.move)
    }
}

struct SkelfRootView: View {
    @Bindable var model: SkelfModel
    var body: some View {
        NavigationStack(path: $model.path) {
            FolderScreen(model: model, folderId: model.folders.rootId)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .folder(let id): FolderScreen(model: model, folderId: id)
                    case .skill(let id): SkillDetailScreen(model: model, skillId: id)
                    }
                }
        }
    }
}

struct FolderScreen: View {
    let model: SkelfModel
    let folderId: String
    @State private var query = ""

    var body: some View {
        let token = model.reloadToken
        let favTok = model.favoritesToken
        let hasClip = model.clip != nil
        let clipName = model.clip?.name ?? ""
        GridRepresentable(model: model, folderId: folderId, query: query, filter: 0, token: token, favToken: favTok,
                          onOpenSkill: { model.path.append(.skill($0)) },
                          onOpenFolder: { model.path.append(.folder($0)) })
            .navigationTitle(folderId == model.folders.rootId ? "Skelf" : model.folderName(folderId))
            .searchable(text: $query, prompt: "Search this folder")
            .toolbar {
                if hasClip {
                    ToolbarItem {
                        Button { model.pasteInto(folderId) } label: {
                            Label("Paste \(clipName)", systemImage: "doc.on.clipboard")
                        }
                    }
                }
                ToolbarItem {
                    Button { model.newFolder(in: folderId) } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                }
            }
    }
}

struct SkillDetailScreen: View {
    let model: SkelfModel
    let skillId: String

    var body: some View {
        let token = model.reloadToken
        let favTok = model.favoritesToken
        let fav = model.favorites.isFavorite(skillId)
        DetailRepresentable(model: model, skillId: skillId, token: token, favToken: favTok)
            .navigationTitle(model.skill(skillId)?.name ?? skillId)
            .toolbar {
                ToolbarItem {
                    Button { if let s = model.skill(skillId) { model.copySkill(s) } } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
                ToolbarItem {
                    Button { model.favorites.toggle(skillId) } label: {
                        Label("Favorite", systemImage: fav ? "star.fill" : "star")
                    }
                }
            }
    }
}

struct GridRepresentable: NSViewControllerRepresentable {
    let model: SkelfModel
    let folderId: String
    let query: String
    let filter: Int
    let token: Int
    let favToken: Int
    let onOpenSkill: (String) -> Void
    let onOpenFolder: (String) -> Void

    func makeNSViewController(context: Context) -> GridViewController {
        let vc = GridViewController(model: model, folderId: folderId)
        vc.onOpenSkill = onOpenSkill
        vc.onOpenFolder = onOpenFolder
        return vc
    }
    func updateNSViewController(_ vc: GridViewController, context: Context) {
        vc.onOpenSkill = onOpenSkill
        vc.onOpenFolder = onOpenFolder
        vc.apply(query: query, filter: filter, token: token)
        vc.refreshFavorites()   // favorite-only changes: update stars in place, no reload
    }
}

struct DetailRepresentable: NSViewRepresentable {
    let model: SkelfModel
    let skillId: String
    let token: Int
    let favToken: Int

    final class Coordinator { var lastSkillId = ""; var lastToken = -1 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SkillDetailView {
        let v = SkillDetailView(frame: .zero)
        v.setShowsBackBar(false)
        v.onCopy = { model.copySkill($0) }
        v.onToggleFavorite = { model.favorites.toggle($0.id) }
        v.onOrganize = { skill, anchor in
            let menu = folderPickerMenu(model.folders) { target in
                model.folders.copySkill(skill.id, to: target); Sound.play(.move)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
        }
        return v
    }
    func updateNSView(_ v: SkillDetailView, context: Context) {
        let c = context.coordinator
        // full reconfigure (re-renders the SKILL.md) only when the skill or data changes…
        if let s = model.skill(skillId), c.lastSkillId != skillId || c.lastToken != token {
            v.configure(s, isFavorite: model.favorites.isFavorite(skillId))
            c.lastSkillId = skillId; c.lastToken = token
        }
        v.setFavorite(model.favorites.isFavorite(skillId))   // …favorite-only changes are a light update
    }
}

// MARK: - Menu-bar popover (Passwords-style: Favorites + Folders containers)

final class ActionButton: NSButton {
    var onAction: (() -> Void)?
    @objc func fire() { onAction?() }
}

final class ClickableRow: NSView, NSDraggingSource {
    var onClick: (() -> Void)?
    var dragPayload: String?           // "skill:<id>"; nil = not draggable
    var onDrop: ((String) -> Bool)?    // accept a dropped payload; nil = not a drop target

    private var trackingArea: NSTrackingArea?
    private var mouseDownPoint: NSPoint = .zero
    private var didDrag = false
    private var hovering = false
    private var dropActive = false

    func enableDrops() { registerForDraggedTypes([skelfEntryType]) }

    // click vs. drag
    override func mouseDown(with event: NSEvent) { mouseDownPoint = event.locationInWindow; didDrag = false }
    override func mouseDragged(with event: NSEvent) {
        guard let payload = dragPayload, !didDrag else { return }
        let p = event.locationInWindow
        if hypot(p.x - mouseDownPoint.x, p.y - mouseDownPoint.y) > 5 {
            didDrag = true
            let pbItem = NSPasteboardItem()
            pbItem.setString(payload, forType: skelfEntryType)
            let di = NSDraggingItem(pasteboardWriter: pbItem)
            di.setDraggingFrame(bounds, contents: snapshot())
            beginDraggingSession(with: [di], event: event, source: self)
        }
    }
    override func mouseUp(with event: NSEvent) { if !didDrag { onClick?() }; didDrag = false }
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .move }

    // drop target
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onDrop != nil, sender.draggingPasteboard.availableType(from: [skelfEntryType]) != nil else { return [] }
        dropActive = true; updateBackground(); return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropActive = false; updateBackground() }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropActive = false; updateBackground() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { onDrop != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropActive = false; updateBackground()
        guard let s = sender.draggingPasteboard.pasteboardItems?.first?.string(forType: skelfEntryType) else { return false }
        return onDrop?(s) ?? false
    }

    // hover
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); trackingArea = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; updateBackground() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateBackground() }

    private func updateBackground() {
        wantsLayer = true
        layer?.cornerRadius = dropActive ? 8 : 0
        if dropActive { layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.30).cgColor }
        else if hovering { layer?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.7).cgColor }
        else { layer?.backgroundColor = NSColor.clear.cgColor }
    }

    private func snapshot() -> NSImage {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage(size: bounds.size) }
        cacheDisplay(in: bounds, to: rep)
        let img = NSImage(size: bounds.size)
        img.addRepresentation(rep)
        return img
    }
}

// A detached Liquid Glass toast that drops in below the popover with a bounce.
final class ToastWindow: NSPanel {
    private let glass = NSGlassEffectView()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let undoBtn = ActionButton()
    var onUndo: (() -> Void)?
    private var dismissWork: DispatchWorkItem?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 46),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView()
        container.wantsLayer = true
        contentView = container

        glass.cornerRadius = 16
        glass.style = .regular
        if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
        glass.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        let inner = NSView()
        inner.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        iconView.contentTintColor = .systemGreen
        iconView.translatesAutoresizingMaskIntoConstraints = false
        inner.addSubview(iconView)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        inner.addSubview(label)
        undoBtn.title = "Undo"
        undoBtn.isBordered = false
        undoBtn.contentTintColor = .controlAccentColor
        undoBtn.font = .systemFont(ofSize: 12.5, weight: .semibold)
        undoBtn.target = undoBtn
        undoBtn.action = #selector(ActionButton.fire)
        undoBtn.onAction = { [weak self] in self?.onUndo?(); self?.dismiss() }
        undoBtn.translatesAutoresizingMaskIntoConstraints = false
        inner.addSubview(undoBtn)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 15),
            iconView.centerYAnchor.constraint(equalTo: inner.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: inner.centerYAnchor),
            undoBtn.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 14),
            undoBtn.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -13),
            undoBtn.centerYAnchor.constraint(equalTo: inner.centerYAnchor),
        ])
        glass.contentView = inner
    }
    override var canBecomeKey: Bool { false }

    /// Toast with an Undo button (used after a drop).
    func present(message: String, width: CGFloat, below popover: NSWindow, onUndo: @escaping () -> Void) {
        self.onUndo = onUndo
        undoBtn.isHidden = false
        iconView.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        iconView.contentTintColor = .systemGreen
        label.stringValue = message
        animateIn(width: width, below: popover, dismissAfter: 4.0)
    }

    /// Plain message toast (no Undo) — e.g. "Copied /name".
    func presentMessage(_ message: String, icon: String, width: CGFloat, below popover: NSWindow) {
        onUndo = nil
        undoBtn.isHidden = true
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        iconView.contentTintColor = .systemGreen
        label.stringValue = message
        animateIn(width: width, below: popover, dismissAfter: 1.8)
    }


    private func animateIn(width w: CGFloat, below popover: NSWindow, dismissAfter: TimeInterval) {
        let h: CGFloat = 46
        let pf = popover.frame
        let x = pf.midX - w / 2
        let targetY = pf.minY - 9 - h
        let target = NSRect(x: x, y: targetY, width: w, height: h)
        let start = target.offsetBy(dx: 0, dy: 12)                       // start tucked under the popover
        let overshoot = NSRect(x: x, y: targetY - 5, width: w, height: h) // dip past, then settle = bounce

        dismissWork?.cancel()
        setFrame(start, display: false)
        alphaValue = 0
        orderFront(nil)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(overshoot, display: true)
            animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrame(target, display: true)
            }
        })

        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissAfter, execute: work)
    }

    func dismiss() {
        dismissWork?.cancel()
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
            animator().setFrame(frame.offsetBy(dx: 0, dy: 8), display: true)
        }, completionHandler: { [weak self] in self?.orderOut(nil) })
    }
}

/// Menu-bar popover. Top level shows two grouped containers — Favorites (copy icon)
/// and Folders (chevron, drill-in). Search reaches every skill. "Open window" lives
/// as an SF window icon in the top-right.
final class PopoverListController: NSViewController, NSSearchFieldDelegate {
    private let store: SkillStore
    private let favorites: Favorites
    private let folders: FolderStore
    var onCopy: ((Skill) -> Void)?
    var onOpen: ((Skill) -> Void)?
    var onOpenApp: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onUndo: (() -> Void)?

    private var currentId: String
    private var query = ""

    private let titleLabel = NSTextField(labelWithString: "Skelf")
    private let backButton = NSButton()
    private let windowButton = NSButton()
    private let optionsButton = NSButton()
    private let searchField = NSSearchField()
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private let contentStack = NSStackView()
    private var toastWindow: ToastWindow?

    private var cardBG: NSColor {
        NSColor(name: nil) { ap in
            let dark = ap.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return dark ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.045)
        }
    }

    init(store: SkillStore, favorites: Favorites, folders: FolderStore) {
        self.store = store; self.favorites = favorites; self.folders = folders
        self.currentId = folders.rootId
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Each time the popover opens, start fresh at the top.
    func prepareForShow() {
        currentId = folders.rootId
        query = ""
        searchField.stringValue = ""
        toastWindow?.dismiss()
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 460))

        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        backButton.imagePosition = .imageOnly
        backButton.isBordered = false
        backButton.focusRingType = .none
        backButton.contentTintColor = .controlAccentColor
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail

        windowButton.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Open Skelf window")
        windowButton.imagePosition = .imageOnly
        windowButton.isBordered = false
        windowButton.focusRingType = .none
        windowButton.contentTintColor = .controlAccentColor
        windowButton.toolTip = "Open Skelf window"
        windowButton.target = self
        windowButton.action = #selector(openApp)
        windowButton.translatesAutoresizingMaskIntoConstraints = false
        windowButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)

        optionsButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Options")
        optionsButton.imagePosition = .imageOnly
        optionsButton.isBordered = false
        optionsButton.focusRingType = .none
        optionsButton.contentTintColor = .controlAccentColor
        optionsButton.toolTip = "Settings & options"
        optionsButton.target = self
        optionsButton.action = #selector(showOptions)
        optionsButton.translatesAutoresizingMaskIntoConstraints = false
        optionsButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)

        // Header: back + title on the left; window + options on the right, each pinned
        // to the title's optical centerline (icons get a small downward nudge because
        // SF-symbol glyphs sit slightly higher than centered text).
        let leftStack = NSStackView(views: [backButton, titleLabel])
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = 5
        leftStack.detachesHiddenViews = true
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(leftStack)
        root.addSubview(windowButton)
        root.addSubview(optionsButton)

        searchField.placeholderString = "Search"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(searchField)

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(contentStack)

        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            leftStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            leftStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: windowButton.leadingAnchor, constant: -8),
            titleLabel.heightAnchor.constraint(equalToConstant: 22),
            backButton.widthAnchor.constraint(equalToConstant: 16),
            backButton.heightAnchor.constraint(equalToConstant: 22),

            optionsButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            optionsButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor, constant: -1),
            optionsButton.widthAnchor.constraint(equalToConstant: 24),
            optionsButton.heightAnchor.constraint(equalToConstant: 24),
            windowButton.trailingAnchor.constraint(equalTo: optionsButton.leadingAnchor, constant: -10),
            windowButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor, constant: -1),
            windowButton.widthAnchor.constraint(equalToConstant: 24),
            windowButton.heightAnchor.constraint(equalToConstant: 24),

            searchField.topAnchor.constraint(equalTo: leftStack.bottomAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),

            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            doc.widthAnchor.constraint(equalTo: clip.widthAnchor),

            contentStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4),
            contentStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 14),
            contentStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -14),
            contentStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -10),
        ])
        view = root
    }

    // A separate Liquid Glass toast that drops in below the popover.
    private func showToast(_ message: String) {
        guard let pop = view.window else { return }
        let tw = toastWindow ?? ToastWindow()
        toastWindow = tw
        tw.present(message: message, width: view.bounds.width, below: pop) { [weak self] in self?.onUndo?() }
    }

    /// "Copied /name" confirmation toast (no Undo) shown when you copy from the menu bar.
    private func showCopiedToast(_ skill: Skill) {
        guard let pop = view.window else { return }
        let tw = toastWindow ?? ToastWindow()
        toastWindow = tw
        tw.presentMessage("Copied \(skill.initiator)", icon: "checkmark.circle.fill",
                          width: view.bounds.width, below: pop)
    }

    /// The toast lives with the menu — when the popover collapses, so does the toast.
    func dismissToast() { toastWindow?.dismiss() }

    // Size the popover to fit its content (shrink when few items; cap + scroll when many).
    private func resizeToFit() {
        view.layoutSubtreeIfNeeded()
        let topChrome: CGFloat = 88      // root top → scroll top (header + search + roomier gaps)
        let bottomPad: CGFloat = 4       // + the contentStack's 10pt bottom inset = 14, matching the sides
        let contentArea = contentStack.fittingSize.height + 14   // doc top(4) + bottom(10) insets
        let maxArea: CGFloat = 430
        let h = topChrome + min(maxArea, contentArea) + bottomPad
        preferredContentSize = NSSize(width: 320, height: max(150, h))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)   // focus search, no stray focus glow
    }

    func reload() {
        if folders.node(currentId) == nil { currentId = folders.rootId }
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let searching = !q.isEmpty

        if searching {
            backButton.isHidden = true; titleLabel.stringValue = "Search"
        } else if currentId == folders.rootId {
            backButton.isHidden = true; titleLabel.stringValue = "Skelf"
        } else {
            backButton.isHidden = false; titleLabel.stringValue = folders.node(currentId)?.name ?? ""
        }

        if searching {
            let matched = favorites.ordered(store.skills.filter {
                $0.name.lowercased().contains(q) || $0.category.lowercased().contains(q) || $0.description.lowercased().contains(q)
            })
            if matched.isEmpty { addEmpty("No skills match.") }
            else { addSection("Results", matched.map { skillRow($0) }) }
        } else if currentId == folders.rootId {
            let favs = favorites.ordered(store.skills.filter { favorites.isFavorite($0.id) })
            let folderRows = folders.menuBarFolders().map { folderRow($0) }   // only user-opted-in folders
            if favs.isEmpty && folderRows.isEmpty {
                addEmpty("Nothing pinned to the menu bar yet.\nFavorite a skill, or add a folder via its ⋯ → Add to Menu Bar —\nor search above to copy any skill.")
            } else {
                if !favs.isEmpty { addSection("Favorites", favs.map { skillRow($0) }) }
                if !folderRows.isEmpty { addSection("Folders", folderRows) }
            }
        } else {
            let skills = favorites.ordered(folders.skillIds(in: currentId).compactMap { id in store.skills.first { $0.id == id } })
            let subRows = folders.childFolders(of: currentId).map { folderRow($0) }
            if skills.isEmpty && subRows.isEmpty { addEmpty("This folder is empty.") }
            else {
                if !skills.isEmpty { addSection("Skills", skills.map { skillRow($0) }) }
                if !subRows.isEmpty { addSection("Folders", subRows) }
            }
        }
        resizeToFit()
    }

    // --- section + card construction ---

    private func addSection(_ title: String, _ rows: [NSView]) {
        let h = NSTextField(labelWithString: title.uppercased())
        h.font = .systemFont(ofSize: 10, weight: .semibold)
        h.textColor = .secondaryLabelColor
        h.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(h)
        let c = card(rows)
        contentStack.addArrangedSubview(c)
        c.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        contentStack.setCustomSpacing(4, after: h)
        contentStack.setCustomSpacing(14, after: c)
    }

    private func addEmpty(_ text: String) {
        let l = NSTextField(wrappingLabelWithString: text)
        l.alignment = .center
        l.font = .systemFont(ofSize: 11)
        l.textColor = .tertiaryLabelColor
        l.translatesAutoresizingMaskIntoConstraints = false
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(l)
        NSLayoutConstraint.activate([
            l.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 44),
            l.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            l.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16),
            l.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -16),
            l.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -10),
        ])
        contentStack.addArrangedSubview(wrap)
        wrap.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func card(_ rows: [NSView]) -> NSView {
        let v = NSStackView()
        v.orientation = .vertical
        v.spacing = 0
        v.alignment = .leading
        v.translatesAutoresizingMaskIntoConstraints = false
        for (i, r) in rows.enumerated() {
            v.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
            r.heightAnchor.constraint(equalToConstant: 48).isActive = true
            if i < rows.count - 1 {
                let sep = NSBox()
                sep.boxType = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                v.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
                sep.heightAnchor.constraint(equalToConstant: 1).isActive = true
            }
        }
        // Liquid Glass card: the row stack rides inside a glass effect view,
        // with corners concentric to the popover (macOS 27).
        let n = rows.count
        let h = CGFloat(n * 48 + max(0, n - 1))
        let glass = GlassCardView()
        glass.cornerRadius = 12
        glass.style = .regular
        glass.contentView = v
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.heightAnchor.constraint(equalToConstant: h).isActive = true
        return glass
    }

    // --- rows ---

    private func makeRow(icon: NSView, title: String, subtitle: String, dim: Bool,
                         trailing: NSView, onBody: @escaping () -> Void) -> ClickableRow {
        let row = ClickableRow()
        row.onClick = onBody
        row.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(icon)
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        t.lineBreakMode = .byTruncatingTail
        if dim { t.textColor = .secondaryLabelColor }
        let s = NSTextField(labelWithString: subtitle)
        s.font = .systemFont(ofSize: 11)
        s.textColor = .secondaryLabelColor
        s.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [t, s])
        text.orientation = .vertical
        text.spacing = 1
        text.alignment = .leading
        text.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(text)
        trailing.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(trailing)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 11),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            text.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            trailing.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8),
        ])
        return row
    }

    private func skillRow(_ skill: Skill) -> NSView {
        let copyBtn = ActionButton()
        copyBtn.isBordered = false
        copyBtn.bezelStyle = .regularSquare
        copyBtn.imageScaling = .scaleProportionallyDown
        copyBtn.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "Copy")
        copyBtn.contentTintColor = .secondaryLabelColor
        copyBtn.toolTip = "Copy \(skill.initiator)"
        copyBtn.target = copyBtn
        copyBtn.action = #selector(ActionButton.fire)
        copyBtn.wantsLayer = true
        copyBtn.widthAnchor.constraint(equalToConstant: 24).isActive = true
        copyBtn.heightAnchor.constraint(equalToConstant: 24).isActive = true
        copyBtn.onAction = { [weak self, weak copyBtn] in
            self?.onCopy?(skill)
            self?.showCopiedToast(skill)                                        // toast: "Copied /name"
            copyBtn?.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Copied")
            copyBtn?.contentTintColor = .systemGreen
            springPop(copyBtn?.layer, from: 0.4, damping: 10, stiffness: 360)   // the copy confirmation pops, not the menu bar
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                copyBtn?.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "Copy")
                copyBtn?.contentTintColor = .secondaryLabelColor
            }
        }
        let sub = skill.enabled ? skill.initiator : "\(skill.initiator)  ·  off"
        let row = makeRow(icon: monogram(skill), title: skill.name, subtitle: sub, dim: !skill.enabled,
                          trailing: copyBtn) { [weak self] in self?.onOpen?(skill) }
        row.dragPayload = "skill:\(skill.id)"     // drag a favorite onto a folder row to file it
        return row
    }

    private func folderRow(_ node: FolderStore.Node) -> NSView {
        let chev = NSImageView()
        chev.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Open folder")
        chev.contentTintColor = .tertiaryLabelColor
        chev.imageScaling = .scaleProportionallyDown
        chev.translatesAutoresizingMaskIntoConstraints = false
        chev.widthAnchor.constraint(equalToConstant: 11).isActive = true
        chev.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let f = node.folders.count, s = node.skills.count
        var parts: [String] = []
        if f > 0 { parts.append("\(f) folder\(f == 1 ? "" : "s")") }
        parts.append("\(s) skill\(s == 1 ? "" : "s")")
        let row = makeRow(icon: folderIcon(), title: node.name, subtitle: parts.joined(separator: " · "),
                          dim: false, trailing: chev) { [weak self] in self?.enter(node.id) }
        row.enableDrops()                          // drop a skill/folder here to move it in
        row.onDrop = { [weak self] payload in self?.handlePopoverDrop(payload, into: node.id) ?? false }
        return row
    }

    private func handlePopoverDrop(_ payload: String, into folderId: String) -> Bool {
        let comps = payload.split(separator: ":", maxSplits: 1).map(String.init)
        guard comps.count == 2 else { return false }
        let folderName = folders.node(folderId)?.name ?? "folder"
        if comps[0] == "folder" {
            guard comps[1] != folderId, !folders.isDescendant(folderId, of: comps[1]) else { return false }
            let name = folders.node(comps[1])?.name ?? "folder"
            folders.moveFolder(comps[1], to: folderId)
            showToast("Moved “\(name)” → \(folderName)")
        } else {
            let name = store.skills.first { $0.id == comps[1] }?.name ?? comps[1]
            folders.moveSkill(comps[1], from: currentId, to: folderId)
            showToast("Moved \(name) → \(folderName)")
        }
        Sound.play(.move)
        return true
    }

    private func monogram(_ skill: Skill) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 7
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 30).isActive = true
        box.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let g = CAGradientLayer()
        g.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        g.cornerRadius = 7
        g.colors = Palette.gradientColors(skill.name)
        g.startPoint = CGPoint(x: 0, y: 0)
        g.endPoint = CGPoint(x: 1, y: 1)
        box.layer?.addSublayer(g)
        let lbl = NSTextField(labelWithString: Palette.initials(skill.name))
        lbl.font = .systemFont(ofSize: 12, weight: .bold)
        lbl.textColor = .white
        lbl.alignment = .center
        lbl.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(lbl)
        lbl.centerXAnchor.constraint(equalTo: box.centerXAnchor).isActive = true
        lbl.centerYAnchor.constraint(equalTo: box.centerYAnchor).isActive = true
        box.alphaValue = skill.enabled ? 1.0 : 0.5
        return box
    }

    private func folderIcon() -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 7
        box.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 30).isActive = true
        box.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let iv = NSImageView()
        iv.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
        iv.contentTintColor = .controlAccentColor
        iv.imageScaling = .scaleProportionallyDown
        iv.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(iv)
        iv.centerXAnchor.constraint(equalTo: box.centerXAnchor).isActive = true
        iv.centerYAnchor.constraint(equalTo: box.centerYAnchor).isActive = true
        iv.widthAnchor.constraint(equalToConstant: 16).isActive = true
        iv.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return box
    }

    // --- navigation ---

    @objc private func goBack() {
        if let p = folders.node(currentId)?.parent { currentId = p; reload(); slideContent(from: -38) }
    }
    private func enter(_ id: String) { currentId = id; reload(); slideContent(from: 38) }

    // Springy directional slide between folder views (drill-in slides from the right, back from the left).
    private func slideContent(from dx: CGFloat) {
        contentStack.wantsLayer = true
        guard let layer = contentStack.layer else { return }
        let slide = CASpringAnimation(keyPath: "transform.translation.x")
        slide.fromValue = dx
        slide.toValue = 0
        slide.damping = 17
        slide.stiffness = 260
        slide.mass = 1
        slide.duration = slide.settlingDuration
        layer.add(slide, forKey: "slide")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        fade.duration = 0.22
        layer.add(fade, forKey: "fade")
    }
    @objc private func openApp() { onOpenApp?() }

    @objc private func showOptions() {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Skelf Window", action: #selector(openApp), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        let refresh = NSMenuItem(title: "Refresh Skills", action: #selector(refreshTapped), keyEquivalent: "r")
        refresh.target = self; menu.addItem(refresh)
        menu.addItem(.separator())
        let sounds = NSMenuItem(title: "Play Sounds", action: #selector(toggleSounds), keyEquivalent: "")
        sounds.target = self; sounds.state = Sound.enabled ? .on : .off; menu.addItem(sounds)
        menu.addItem(.separator())
        let about = NSMenuItem(title: "About Skelf", action: #selector(aboutTapped), keyEquivalent: "")
        about.target = self; menu.addItem(about)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Skelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: optionsButton.bounds.height + 4), in: optionsButton)
    }

    @objc private func refreshTapped() { onRefresh?() }

    @objc private func toggleSounds() { Sound.setEnabled(!Sound.enabled) }

    @objc private func aboutTapped() {
        let a = NSAlert()
        a.messageText = "Skelf"
        a.informativeText = "A menu-bar browser for your installed Claude Code skills.\n\n\(store.skills.count) skills installed."
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    func controlTextDidChange(_ obj: Notification) { query = searchField.stringValue; reload() }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    let store = SkillStore()
    let favorites = Favorites()
    let folders = FolderStore()
    let undoManager = UndoManager()
    var statusItem: NSStatusItem!
    var window: NSWindow?
    var model: SkelfModel?
    var watcher: SkillWatcher?
    let popover = NSPopover()
    var popoverController: PopoverListController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.reload()
        folders.undoManager = undoManager
        folders.syncInstalled(Set(store.skills.map { $0.id }))
        verifyAndCategorize()
        setupMainMenu()
        dlog("launched -> \(store.skills.count) skills")
        // A folder change reloads the grid + popover; a favorite change only updates
        // stars (no destructive grid reload — cards animate their star in place).
        folders.onChange = { [weak self] in
            self?.model?.bumpReload()
            self?.popoverController?.reload()
        }
        favorites.onChange = { [weak self] in
            self?.model?.bumpFavorites()
            self?.popoverController?.reload()
        }
        popover.delegate = self
        setupStatusItem()
        showWindow()
        startWatching()
        if let i = CommandLine.arguments.firstIndex(of: "--open"), i + 1 < CommandLine.arguments.count {
            model?.openSkill(CommandLine.arguments[i + 1])
        }
        if let i = CommandLine.arguments.firstIndex(of: "--enter"), i + 1 < CommandLine.arguments.count {
            model?.enterFolder(CommandLine.arguments[i + 1])
        }
        if CommandLine.arguments.contains("--popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.togglePopover(nil) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }

    // Route the Edit ▸ Undo/Redo (and Cmd-Z) to the folder tree's undo manager.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undoManager }

    // When the menu-bar popover collapses, dismiss its detached toast too.
    func popoverDidClose(_ notification: Notification) { popoverController?.dismissToast() }

    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Skelf", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Skelf", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Skelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = main
    }

    @objc private func showAbout() {
        let a = NSAlert()
        a.messageText = "Skelf"
        a.informativeText = "A menu-bar browser for your installed Claude Code skills.\n\n\(store.skills.count) skills installed."
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    private func startWatching() {
        watcher = SkillWatcher(paths: [store.agentsDir.path, store.claudeDir.path]) { [weak self] in
            self?.reloadFromDisk(auto: true)
        }
        watcher?.start()
    }

    private func reloadFromDisk(auto: Bool) {
        store.reload()
        folders.syncInstalled(Set(store.skills.map { $0.id }))
        verifyAndCategorize()
        popoverController?.reload()
        model?.bumpReload()
        dlog("reload(auto: \(auto)) -> \(store.skills.count) skills")
    }

    private var recatWork: DispatchWorkItem?
    /// True once the skill's actual GitHub page has been confirmed to exist.
    private func skillVerified(_ s: Skill) -> Bool {
        guard let u = s.skillGithubURL?.absoluteString else { return false }
        return GitHubVerifier.shared.status(u) == true
    }
    /// Categorize with what GitHub verification already knows, then HEAD-check the page
    /// of any not-yet-verified skill in the background and re-categorize as they resolve
    /// (a skill slides from the home page into its creator's folder once its page is
    /// confirmed). Skills whose page can't be verified stay unfiled at root.
    private func verifyAndCategorize() {
        folders.autoCategorize(store.skills, isVerified: skillVerified)
        for s in store.skills {
            guard let u = s.skillGithubURL?.absoluteString, GitHubVerifier.shared.status(u) == nil else { continue }
            GitHubVerifier.shared.verify(u) { [weak self] in self?.scheduleRecategorize() }
        }
    }
    private func scheduleRecategorize() {
        recatWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.folders.autoCategorize(self.store.skills, isVerified: self.skillVerified)
            self.model?.bumpReload()
            self.popoverController?.reload()
        }
        recatWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    private func dlog(_ s: String) {
        if ProcessInfo.processInfo.environment["SKILLSHELF_DEBUG"] != nil {
            FileHandle.standardError.write(("[skillshelf] " + s + "\n").data(using: .utf8)!)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = menuBarIcon()
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
    }

    /// The Skelf mark (from skelf.svg) as a menu-bar template image, falling back to an SF symbol.
    private func menuBarIcon() -> NSImage {
        if let p = Bundle.main.path(forResource: "skelf", ofType: "svg"), let img = NSImage(contentsOfFile: p) {
            img.isTemplate = true                              // tints to the menu-bar colour, adapts light/dark
            img.size = NSSize(width: 24, height: 18)           // svg mark is ~1.38:1
            return img
        }
        let fallback = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Skelf")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        fallback.isTemplate = true
        return fallback
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender); return }

        let ctrl: PopoverListController
        if let existing = popoverController {
            ctrl = existing
        } else {
            ctrl = PopoverListController(store: store, favorites: favorites, folders: folders)
            // No status-item flash — that resized the menu-bar icon and shifted the menu
            // bar. The copy confirmation animates on the copy icon itself (see skillRow).
            ctrl.onCopy = { [weak self] skill in self?.copy(skill) }
            ctrl.onOpen = { [weak self] skill in
                self?.popover.performClose(nil)
                self?.showWindow()
                self?.model?.openSkill(skill.id)
            }
            ctrl.onOpenApp = { [weak self] in
                self?.popover.performClose(nil)
                self?.showWindow()
            }
            ctrl.onRefresh = { [weak self] in self?.reloadFromDisk(auto: false) }
            ctrl.onUndo = { [weak self] in self?.undoManager.undo() }
            popoverController = ctrl
        }

        popover.contentViewController = ctrl
        popover.behavior = .transient
        ctrl.prepareForShow()
        ctrl.reload()   // sets preferredContentSize -> popover sizes to fit
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func copy(_ skill: Skill) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(skill.initiator, forType: .string)
        Sound.play(.copy)
    }

    private func showWindow() {
        if window == nil {
            let m = SkelfModel(store: store, favorites: favorites, folders: folders,
                               copySkill: { [weak self] skill in self?.copy(skill) })
            model = m
            // SwiftUI navigation shell, bridged into the AppKit window so its
            // .navigationTitle + .toolbar drive the window's Liquid Glass toolbar.
            let host = NSHostingController(rootView: SkelfRootView(model: m))
            host.sceneBridgingOptions = [.title, .toolbars]
            // Create with an explicit frame, THEN attach the content VC, so the window
            // keeps 760×580 instead of collapsing to the content's fitting size.
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 660),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.contentViewController = host
            w.title = "Skelf"
            w.minSize = NSSize(width: 680, height: 460)
            w.setContentSize(NSSize(width: 920, height: 660))
            w.center()
            w.isReleasedWhenClosed = false
            w.delegate = self            // for windowWillReturnUndoManager
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Entry point

@main
struct SkillShelfMain {
    static func main() {
        if CommandLine.arguments.contains("--list") {
            let store = SkillStore()
            store.reload()
            let on = store.skills.filter { $0.enabled }.count
            print("Skelf — \(store.skills.count) skills (\(on) enabled, \(store.skills.count - on) off)")
            for s in store.skills {
                let mark = s.enabled ? "●" : "○"
                print("\(mark) \(s.initiator.padding(toLength: 28, withPad: " ", startingAt: 0)) [\(s.category)]  \(s.source)")
            }
            exit(0)
        }
        if let idx = CommandLine.arguments.firstIndex(of: "--copy"), idx + 1 < CommandLine.arguments.count {
            let id = CommandLine.arguments[idx + 1]
            let store = SkillStore()
            store.reload()
            guard let skill = store.skills.first(where: { $0.id == id }) else {
                FileHandle.standardError.write("no such skill: \(id)\n".data(using: .utf8)!)
                exit(1)
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(skill.initiator, forType: .string)
            print("copied \(skill.initiator) to clipboard")
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
