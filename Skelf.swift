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
    var githubURL: URL? {
        guard source.contains("/") else { return nil }
        return URL(string: "https://github.com/\(source)")
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

    /// Group each creator's skills into an auto-folder. Root is "unfiled": any skill
    /// sitting at root is moved into its creator's auto-folder (created on demand);
    /// skills the user has filed into their own folders are left untouched. Runs on
    /// every reload, so newly-installed skills self-file under their creator.
    func autoCategorize(_ installed: [Skill]) {
        var changed = false
        let creatorOf = Dictionary(installed.map { ($0.id, Self.creatorName($0.source)) },
                                   uniquingKeysWith: { a, _ in a })

        func autoFolderId(for creator: String) -> String {
            if let existing = nodes.values.first(where: { $0.autoCreator == creator }) { return existing.id }
            let id = "auto-" + UUID().uuidString.prefix(8)
            nodes[id] = Node(id: id, name: creator, parent: rootId, folders: [], skills: [], autoCreator: creator)
            nodes[rootId]?.folders.append(id)
            changed = true
            return id
        }

        for sid in (nodes[rootId]?.skills ?? []) {
            guard let creator = creatorOf[sid] else { continue }
            let fid = autoFolderId(for: creator)
            nodes[rootId]?.skills.removeAll { $0 == sid }
            if !(nodes[fid]?.skills.contains(sid) ?? true) { nodes[fid]?.skills.append(sid) }
            changed = true
        }

        // drop auto-folders that ended up empty (e.g. their creator's skills were uninstalled)
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

// MARK: - Grid tile

// A per-skill "image": a rich diagonal gradient + soft radial light + a large faint
// monogram subject + a bottom scrim for legible text. Reused by the grid card and the
// detail header so a skill looks the same wherever it appears.
final class SkillArtView: NSView {
    private let base = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let mono = CATextLayer()
    private let scrim = CAGradientLayer()
    var showSubject = true { didSet { mono.isHidden = !showSubject } }
    var subjectFraction: CGFloat = 0.62   // monogram size relative to the smaller edge

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        base.startPoint = CGPoint(x: 0.0, y: 1.0); base.endPoint = CGPoint(x: 1.0, y: 0.0)
        glow.type = .radial
        glow.colors = [NSColor.white.withAlphaComponent(0.42).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        glow.startPoint = CGPoint(x: 0.7, y: 0.8); glow.endPoint = CGPoint(x: 1.35, y: 1.45)
        mono.alignmentMode = .center
        mono.foregroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        mono.font = NSFont.systemFont(ofSize: 10, weight: .heavy)
        mono.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        scrim.startPoint = CGPoint(x: 0.5, y: 0.0); scrim.endPoint = CGPoint(x: 0.5, y: 1.0)
        scrim.colors = [NSColor.black.withAlphaComponent(0.74).cgColor,
                        NSColor.black.withAlphaComponent(0.10).cgColor,
                        NSColor.clear.cgColor]
        scrim.locations = [0.0, 0.46, 1.0]
        layer?.addSublayer(base)
        layer?.addSublayer(glow)
        layer?.addSublayer(mono)
        layer?.addSublayer(scrim)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        for l in [base, glow, scrim] { l.frame = bounds }
        let fs = max(40, min(bounds.width, bounds.height) * subjectFraction)
        mono.fontSize = fs
        mono.frame = CGRect(x: 0, y: bounds.height * 0.40, width: bounds.width, height: fs * 1.25)
    }

    func configure(_ name: String, enabled: Bool = true) {
        base.colors = Palette.gradientColors(name)
        mono.string = Palette.initials(name)
        layer?.opacity = enabled ? 1.0 : 0.9
    }
}

// MARK: - Grid tile (skill card — image background, à la the product-card reference)

final class SkillGridItem: NSCollectionViewItem {
    private let art = SkillArtView()
    private let favButton = NSButton()
    private let menuButton = NSButton()
    private let nameLabel = NSTextField(labelWithString: "")
    private let initiatorBox = NSView()
    private let initiatorLabel = NSTextField(labelWithString: "")
    private let descLabel = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton()
    private var hovering = false
    var onMenu: ((NSView) -> Void)?
    var onToggleFavorite: (() -> Void)?
    var onCopy: (() -> Void)?

    private func styleCircle(_ b: NSButton, _ symbol: String, _ action: Selector) {
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 14
        b.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.34).cgColor
        b.bezelStyle = .regularSquare
        b.imageScaling = .scaleProportionallyDown
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.contentTintColor = .white
        b.imagePosition = .imageOnly
        b.focusRingType = .none
        b.target = self
        b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
    }

    override func loadView() {
        let root = NSView()
        art.translatesAutoresizingMaskIntoConstraints = false
        art.layer?.cornerRadius = 22
        art.subjectFraction = 0.5
        root.addSubview(art)

        styleCircle(favButton, "star", #selector(favClicked))
        styleCircle(menuButton, "ellipsis", #selector(menuClicked))
        let controls = NSStackView(views: [favButton, menuButton])
        controls.orientation = .horizontal
        controls.spacing = 6
        controls.translatesAutoresizingMaskIntoConstraints = false
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
            favButton.widthAnchor.constraint(equalToConstant: 28),
            favButton.heightAnchor.constraint(equalToConstant: 28),
            menuButton.widthAnchor.constraint(equalToConstant: 28),
            menuButton.heightAnchor.constraint(equalToConstant: 28),

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

    func configure(_ skill: Skill, isFavorite: Bool) {
        art.configure(skill.name, enabled: skill.enabled)
        nameLabel.stringValue = skill.name
        initiatorLabel.stringValue = skill.enabled ? skill.category : "off"
        initiatorBox.layer?.backgroundColor = (skill.enabled ? NSColor.black.withAlphaComponent(0.44)
                                                             : NSColor.systemRed.withAlphaComponent(0.55)).cgColor
        descLabel.stringValue = skill.description.isEmpty ? "No description in SKILL.md." : skill.description
        favButton.image = NSImage(systemSymbolName: isFavorite ? "star.fill" : "star",
                                  accessibilityDescription: isFavorite ? "Favorited" : "Favorite")
        favButton.contentTintColor = isFavorite ? .systemYellow : .white
        setCopyTitle("Copy")
        view.alphaValue = skill.enabled ? 1.0 : 0.6
        view.toolTip = "\(skill.initiator)\n\n\(skill.description)"
    }

    @objc private func favClicked() { onToggleFavorite?() }
    @objc private func menuClicked() { onMenu?(menuButton) }
    @objc private func copyClicked() {
        onCopy?()
        springPop(copyButton.layer, from: 0.9)
        setCopyTitle("Copied ✓")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in self?.setCopyTitle("Copy") }
    }

    func pressPop() { springPop(art.layer, from: 0.96) }

    override func mouseEntered(with event: NSEvent) { hovering = true; applyHover() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyHover() }
    private func applyHover() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14; ctx.allowsImplicitAnimation = true
            self.art.layer?.transform = self.hovering
                ? CATransform3DScale(CATransform3DIdentity, 1.02, 1.02, 1) : CATransform3DIdentity
        }
    }
    override var isSelected: Bool {
        didSet {
            art.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
            art.layer?.borderWidth = isSelected ? 2 : 0
        }
    }
}

// MARK: - Folder tile (same card shape, folder treatment)

final class FolderGridItem: NSCollectionViewItem {
    private let art = SkillArtView()
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let menuButton = NSButton()
    private let barBadge = NSImageView()
    private var hovering = false
    var onMenu: ((NSView) -> Void)?

    override func loadView() {
        let root = NSView()
        art.translatesAutoresizingMaskIntoConstraints = false
        art.layer?.cornerRadius = 22
        art.showSubject = false
        root.addSubview(art)

        icon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.92)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 54, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(icon)

        menuButton.isBordered = false
        menuButton.wantsLayer = true
        menuButton.layer?.cornerRadius = 14
        menuButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.34).cgColor
        menuButton.bezelStyle = .regularSquare
        menuButton.imageScaling = .scaleProportionallyDown
        menuButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")
        menuButton.contentTintColor = .white
        menuButton.focusRingType = .none
        menuButton.target = self
        menuButton.action = #selector(menuClicked)
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(menuButton)

        barBadge.image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: "In menu bar")
        barBadge.contentTintColor = .white
        barBadge.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        barBadge.translatesAutoresizingMaskIntoConstraints = false
        barBadge.isHidden = true
        root.addSubview(barBadge)

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

            icon.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -18),

            menuButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            menuButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            menuButton.widthAnchor.constraint(equalToConstant: 28),
            menuButton.heightAnchor.constraint(equalToConstant: 28),

            barBadge.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            barBadge.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),

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
        art.configure(node.name, enabled: true)
        nameLabel.stringValue = node.name
        let s = node.skills.count, f = node.folders.count
        var parts: [String] = []
        if f > 0 { parts.append("\(f) folder\(f == 1 ? "" : "s")") }
        parts.append("\(s) skill\(s == 1 ? "" : "s")")
        countLabel.stringValue = parts.joined(separator: " · ")
        barBadge.isHidden = !inMenuBar
        view.toolTip = node.name
    }

    @objc private func menuClicked() { onMenu?(menuButton) }
    func pressPop() { springPop(art.layer, from: 0.96) }

    override func mouseEntered(with event: NSEvent) { hovering = true; applyHover() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyHover() }
    private func applyHover() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14; ctx.allowsImplicitAnimation = true
            self.art.layer?.transform = self.hovering
                ? CATransform3DScale(CATransform3DIdentity, 1.02, 1.02, 1) : CATransform3DIdentity
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

final class SkillDetailView: NSView {
    var onBack: (() -> Void)?
    var onCopy: ((Skill) -> Void)?
    var onToggleFavorite: ((Skill) -> Void)?
    var onOrganize: ((Skill, NSView) -> Void)?
    private var skill: Skill?

    // Navigation chrome — collapsed when hosted inside a SwiftUI NavigationStack.
    private let backBar = NSView()
    private let topDivider = NSBox()
    private var backBarHeight: NSLayoutConstraint!

    // hero
    private let glyph = GradientView()
    private let initialsLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let initiatorBox = NSView()
    private let initiatorLabel = NSTextField(labelWithString: "")
    private let statusBox = NSView()
    private let statusLabel = NSTextField(labelWithString: "")

    // primary action
    private let copyButton = NSButton()
    private let copyGlass = NSGlassEffectView()

    // meta bento + description
    private let metaColumn = NSStackView()
    private let descLabel = NSTextField(wrappingLabelWithString: "")
    private var copiedWork: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Hide the in-view back bar (used when a SwiftUI toolbar provides the back chevron).
    func setShowsBackBar(_ show: Bool) {
        backBar.isHidden = !show
        topDivider.isHidden = !show
        backBarHeight.constant = show ? 40 : 0
    }

    private func styleLinkButton(_ b: NSButton, _ title: String, _ symbol: String) {
        b.title = title
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.imagePosition = .imageLeading
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.translatesAutoresizingMaskIntoConstraints = false
    }

    private func iconButton(_ symbol: String, _ action: Selector) -> NSButton {
        let b = NSButton()
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imageScaling = .scaleProportionallyDown
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.contentTintColor = .secondaryLabelColor
        b.focusRingType = .none
        b.target = self
        b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return b
    }

    private func capsule(_ box: NSView, _ label: NSTextField, font: NSFont) {
        box.wantsLayer = true
        box.layer?.cornerRadius = 9
        box.translatesAutoresizingMaskIntoConstraints = false
        label.font = font
        label.drawsBackground = false
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -3),
        ])
    }

    private func build() {
        // --- nav chrome (back bar) ---
        backBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backBar)
        let back = NSButton(title: "All skills", target: self, action: #selector(backTapped))
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        back.imagePosition = .imageLeading
        back.bezelStyle = .recessed
        back.isBordered = false
        back.contentTintColor = .controlAccentColor
        back.font = skelfFont(.callout, .medium)
        back.translatesAutoresizingMaskIntoConstraints = false
        backBar.addSubview(back)

        topDivider.boxType = .separator
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topDivider)

        // --- scroll area + content stack ---
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        addSubview(scroll)
        let clip = scroll.contentView
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(content)

        // hero block
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.gradient.cornerRadius = 16
        initialsLabel.font = skelfFont(.title1, .bold)
        initialsLabel.textColor = .white
        initialsLabel.alignment = .center
        initialsLabel.translatesAutoresizingMaskIntoConstraints = false
        glyph.addSubview(initialsLabel)

        nameLabel.font = skelfFont(.title2, .bold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 2
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        capsule(initiatorBox, initiatorLabel, font: skelfMono(.callout, .medium))
        initiatorBox.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        initiatorLabel.textColor = .controlAccentColor
        capsule(statusBox, statusLabel, font: skelfFont(.caption1, .semibold))

        let chipRow = NSStackView(views: [initiatorBox, statusBox])
        chipRow.orientation = .horizontal
        chipRow.spacing = 8
        chipRow.alignment = .centerY
        chipRow.translatesAutoresizingMaskIntoConstraints = false

        let heroText = NSStackView(views: [nameLabel, chipRow])
        heroText.orientation = .vertical
        heroText.alignment = .leading
        heroText.spacing = 8
        heroText.translatesAutoresizingMaskIntoConstraints = false

        let favBtn = iconButton("star", #selector(favoriteTapped))
        favoriteButtonRef = favBtn
        let folderBtn = iconButton("folder.badge.plus", #selector(organizeTapped))
        folderButtonRef = folderBtn
        let heroActions = NSStackView(views: [favBtn, folderBtn])
        heroActions.orientation = .horizontal
        heroActions.spacing = 2
        heroActions.translatesAutoresizingMaskIntoConstraints = false

        let hero = NSView()
        hero.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(glyph); hero.addSubview(heroText); hero.addSubview(heroActions)
        content.addArrangedSubview(hero)

        // primary action — Liquid Glass Copy pill
        copyButton.isBordered = false
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .large
        copyButton.keyEquivalent = "\r"
        copyButton.font = skelfFont(.headline, .semibold)
        copyButton.contentTintColor = .white
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyGlass.cornerRadius = 22
        copyGlass.tintColor = .controlAccentColor
        copyGlass.contentView = copyButton
        copyGlass.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 27.0, *) { copyGlass.effectIsInteractive = true }
        content.addArrangedSubview(copyGlass)

        // meta bento
        metaColumn.orientation = .vertical
        metaColumn.alignment = .leading
        metaColumn.distribution = .fill
        metaColumn.spacing = 12
        metaColumn.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(metaColumn)

        // description
        let descBlock = NSView()
        descBlock.translatesAutoresizingMaskIntoConstraints = false
        let descHeader = NSTextField(labelWithString: "DESCRIPTION")
        descHeader.font = skelfFont(.caption2, .semibold)
        descHeader.textColor = .tertiaryLabelColor
        descHeader.translatesAutoresizingMaskIntoConstraints = false
        descBlock.addSubview(descHeader)
        descLabel.font = skelfFont(.body)
        descLabel.textColor = .labelColor
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        descBlock.addSubview(descLabel)
        content.addArrangedSubview(descBlock)

        // secondary actions
        let revealBtn = NSButton(title: "Reveal SKILL.md", target: self, action: #selector(revealTapped))
        styleLinkButton(revealBtn, "Reveal SKILL.md", "doc.text")
        let githubBtn = NSButton(title: "View on GitHub", target: self, action: #selector(githubTapped))
        styleLinkButton(githubBtn, "View on GitHub", "arrow.up.right.square")
        let links = NSStackView(views: [revealBtn, githubBtn])
        links.orientation = .horizontal
        links.spacing = 8
        links.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(links)

        content.setCustomSpacing(22, after: hero)
        content.setCustomSpacing(24, after: copyGlass)
        content.setCustomSpacing(24, after: metaColumn)
        content.setCustomSpacing(20, after: descBlock)

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

            scroll.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            doc.widthAnchor.constraint(equalTo: clip.widthAnchor),

            content.topAnchor.constraint(equalTo: doc.topAnchor, constant: 24),
            content.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -24),
            content.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -24),

            // hero internal layout
            hero.widthAnchor.constraint(equalTo: content.widthAnchor),
            glyph.topAnchor.constraint(equalTo: hero.topAnchor),
            glyph.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 64),
            glyph.heightAnchor.constraint(equalToConstant: 64),
            hero.bottomAnchor.constraint(greaterThanOrEqualTo: glyph.bottomAnchor),
            initialsLabel.centerXAnchor.constraint(equalTo: glyph.centerXAnchor),
            initialsLabel.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            heroActions.topAnchor.constraint(equalTo: hero.topAnchor, constant: 2),
            heroActions.trailingAnchor.constraint(equalTo: hero.trailingAnchor),
            heroText.topAnchor.constraint(equalTo: glyph.topAnchor),
            heroText.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 16),
            heroText.trailingAnchor.constraint(lessThanOrEqualTo: heroActions.leadingAnchor, constant: -12),
            hero.bottomAnchor.constraint(greaterThanOrEqualTo: heroText.bottomAnchor),
            statusBox.heightAnchor.constraint(equalToConstant: 20),
            initiatorBox.heightAnchor.constraint(equalToConstant: 20),

            // primary action
            copyGlass.heightAnchor.constraint(equalToConstant: 44),
            copyGlass.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            copyGlass.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor),

            // meta + description span the content width
            metaColumn.widthAnchor.constraint(equalTo: content.widthAnchor),
            descBlock.widthAnchor.constraint(equalTo: content.widthAnchor),
            descHeader.topAnchor.constraint(equalTo: descBlock.topAnchor),
            descHeader.leadingAnchor.constraint(equalTo: descBlock.leadingAnchor),
            descLabel.topAnchor.constraint(equalTo: descHeader.bottomAnchor, constant: 8),
            descLabel.leadingAnchor.constraint(equalTo: descBlock.leadingAnchor),
            descLabel.trailingAnchor.constraint(lessThanOrEqualTo: descBlock.trailingAnchor),
            descLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            descLabel.bottomAnchor.constraint(equalTo: descBlock.bottomAnchor),
        ])
    }

    private weak var favoriteButtonRef: NSButton?
    private weak var folderButtonRef: NSButton?

    // A bento row of equal-width cards (one card = full width).
    private func metaRow(_ cards: [NSView]) -> NSView {
        let row = NSStackView(views: cards)
        row.orientation = .horizontal
        row.distribution = cards.count > 1 ? .fillEqually : .fill
        row.alignment = .top
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    func configure(_ skill: Skill, isFavorite: Bool) {
        self.skill = skill
        initialsLabel.stringValue = Palette.initials(skill.name)
        nameLabel.stringValue = skill.name
        glyph.gradient.colors = Palette.gradientColors(skill.name)

        initiatorLabel.stringValue = skill.initiator
        statusLabel.stringValue = skill.enabled ? "● Enabled" : "○ Off"
        statusLabel.textColor = skill.enabled ? .systemGreen : .secondaryLabelColor
        statusBox.layer?.backgroundColor = (skill.enabled ? NSColor.systemGreen : NSColor.systemGray)
            .withAlphaComponent(0.16).cgColor

        favoriteButtonRef?.image = NSImage(systemSymbolName: isFavorite ? "star.fill" : "star",
                                           accessibilityDescription: isFavorite ? "Favorited" : "Favorite")
        favoriteButtonRef?.contentTintColor = isFavorite ? .systemYellow : .secondaryLabelColor
        favoriteButtonRef?.toolTip = isFavorite ? "Unpin from favorites" : "Pin to favorites"
        folderButtonRef?.toolTip = "Add to a folder…"

        copyButton.title = "Copy  \(skill.initiator)"

        metaColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let version = MetaCardView(key: "Version", value: skill.version ?? "unversioned", mono: false)
        let category = MetaCardView(key: "Category", value: skill.category, mono: false)
        let files = MetaCardView(key: "Files", value: "\(skill.fileCount)", mono: false)
        let installed = MetaCardView(key: "Installed", value: skill.installedAt, mono: false)
        let source = MetaCardView(key: "Source", value: skill.source, mono: false)
        let path = MetaCardView(key: "Path", value: skill.skillPath, mono: true)
        metaColumn.addArrangedSubview(metaRow([version, category]))
        metaColumn.addArrangedSubview(metaRow([files, installed]))
        metaColumn.addArrangedSubview(metaRow([source]))
        metaColumn.addArrangedSubview(metaRow([path]))
        for row in metaColumn.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: metaColumn.widthAnchor).isActive = true
        }

        descLabel.stringValue = skill.description.isEmpty ? "No description in SKILL.md." : skill.description
    }

    @objc private func backTapped() { onBack?() }

    @objc private func favoriteTapped() {
        guard let skill = skill else { return }
        onToggleFavorite?(skill)
    }

    @objc private func organizeTapped() {
        guard let skill = skill else { return }
        onOrganize?(skill, folderButtonRef ?? self)
    }

    @objc private func copyTapped() {
        guard let skill = skill else { return }
        onCopy?(skill)
        springPop(copyGlass.layer, from: 0.94)
        copyButton.title = "Copied  ✓"
        copiedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let s = self.skill else { return }
            self.copyButton.title = "Copy  \(s.initiator)"
        }
        copiedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    @objc private func revealTapped() {
        guard let skill = skill else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: skill.skillMDPath)])
    }

    @objc private func githubTapped() {
        guard let url = skill?.githubURL else { return }
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

// The grid for ONE folder. Navigation + toolbar live in SwiftUI; this renders the
// folder's entries, handles drag/drop/reorder + per-tile menus, and reports clicks.
final class GridViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let model: SkelfModel
    var folderId: String
    var onOpenSkill: ((String) -> Void)?
    var onOpenFolder: ((String) -> Void)?

    private var entries: [GridEntry] = []
    private var query = ""
    private var filterMode = 0
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

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 224, height: 298)
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 18
        layout.sectionInset = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(SkillGridItem.self, forItemWithIdentifier: skillItemID)
        collectionView.register(FolderGridItem.self, forItemWithIdentifier: folderItemID)
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

    /// Called by the SwiftUI host whenever search / filter / data changes.
    func apply(query: String, filter: Int, token: Int) {
        guard query != self.query || filter != filterMode || token != lastToken else { return }
        self.query = query; self.filterMode = filter; lastToken = token
        if isViewLoaded { reload() }
    }

    func reload() { buildEntries(); collectionView.reloadData() }

    private func buildEntries() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var e: [GridEntry] = []
        for f in model.folders.childFolders(of: folderId) where q.isEmpty || f.name.lowercased().contains(q) {
            e.append(.folder(f))
        }
        let here = model.folders.skillIds(in: folderId).compactMap { id in model.store.skills.first { $0.id == id } }
        let matched = here.filter { s in
            let passFilter = filterMode == 0 || (filterMode == 1 && s.enabled) || (filterMode == 2 && !s.enabled)
            let passQuery = q.isEmpty
                || s.name.lowercased().contains(q)
                || s.description.lowercased().contains(q)
                || s.category.lowercased().contains(q)
                || s.source.lowercased().contains(q)
            return passFilter && passQuery
        }
        for s in model.favorites.ordered(matched) { e.append(.skill(s)) }
        entries = e
    }

    private func activate(_ ip: IndexPath) {
        guard ip.item < entries.count else { return }
        switch entries[ip.item] {
        case .folder(let n): (collectionView.item(at: ip) as? FolderGridItem)?.pressPop(); onOpenFolder?(n.id)
        case .skill(let s): (collectionView.item(at: ip) as? SkillGridItem)?.pressPop(); onOpenSkill?(s.id)
        }
        collectionView.deselectAll(nil)
    }

    // --- collection data ---
    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard indexPath.item < entries.count else {
            return cv.makeItem(withIdentifier: skillItemID, for: indexPath)
        }
        switch entries[indexPath.item] {
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
                grid.configure(skill, isFavorite: model.favorites.isFavorite(skill.id))
                grid.onToggleFavorite = { [weak self] in self?.model.favorites.toggle(skill.id) }
                grid.onCopy = { [weak self] in self?.model.copySkill(skill) }
                grid.onMenu = { [weak self] anchor in
                    guard let self = self else { return }
                    self.popMenu(self.skillMenu(skill), at: anchor)
                }
            }
            item.view.menu = skillMenu(skill)
            return item
        }
    }

    private func popMenu(_ menu: NSMenu, at anchor: NSView) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 2), in: anchor)
    }

    // --- drag & drop / reorder ---
    func collectionView(_ cv: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        return query.trimmingCharacters(in: .whitespaces).isEmpty && filterMode == 0
    }

    func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard indexPath.item < entries.count else { return nil }
        let item = NSPasteboardItem()
        switch entries[indexPath.item] {
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
        if proposedDropOperation.pointee == .on {
            if idx.item < entries.count, case .folder = entries[idx.item] {
                return .move
            }
            proposedDropOperation.pointee = .before
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

        if dropOperation == .on, indexPath.item < entries.count, case .folder(let target) = entries[indexPath.item] {
            if isFolder { model.folders.moveFolder(draggedId, to: target.id) }
            else { model.folders.moveSkill(draggedId, from: folderId, to: target.id) }
            Sound.play(.move)
            return true
        }
        let anchor = anchorId(forKind: isFolder, atEntryIndex: indexPath.item)
        if isFolder { model.folders.reorderFolder(draggedId, in: folderId, before: anchor) }
        else { model.folders.reorderSkill(draggedId, in: folderId, before: anchor) }
        Sound.play(.move)
        return true
    }

    private func anchorId(forKind isFolder: Bool, atEntryIndex idx: Int) -> String? {
        var i = max(0, idx)
        while i < entries.count {
            switch entries[i] {
            case .folder(let n): if isFolder { return n.id }
            case .skill(let s): if !isFolder { return s.id }
            }
            i += 1
        }
        return nil
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

    struct Clip { let id: String; let isFolder: Bool; let cut: Bool; let source: String; let name: String }
    var clip: Clip?

    init(store: SkillStore, favorites: Favorites, folders: FolderStore, copySkill: @escaping (Skill) -> Void) {
        self.store = store
        self.favorites = favorites
        self.folders = folders
        self.copySkill = copySkill
    }

    func bumpReload() { reloadToken &+= 1 }
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
    @State private var filter = 0

    var body: some View {
        let token = model.reloadToken
        let hasClip = model.clip != nil
        let clipName = model.clip?.name ?? ""
        GridRepresentable(model: model, folderId: folderId, query: query, filter: filter, token: token,
                          onOpenSkill: { model.path.append(.skill($0)) },
                          onOpenFolder: { model.path.append(.folder($0)) })
            .navigationTitle(folderId == model.folders.rootId ? "Skelf" : model.folderName(folderId))
            .searchable(text: $query, prompt: "Search this folder")
            .toolbar {
                ToolbarItem {
                    Picker("Filter", selection: $filter) {
                        Text("All").tag(0)
                        Text("Enabled").tag(1)
                        Text("Off").tag(2)
                    }
                    .pickerStyle(.menu)
                }
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
        let fav = model.favorites.isFavorite(skillId)
        DetailRepresentable(model: model, skillId: skillId, token: token)
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
    }
}

struct DetailRepresentable: NSViewRepresentable {
    let model: SkelfModel
    let skillId: String
    let token: Int

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
        if let s = model.skill(skillId) { v.configure(s, isFavorite: model.favorites.isFavorite(skillId)) }
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

    func present(message: String, below popover: NSWindow, onUndo: @escaping () -> Void) {
        self.onUndo = onUndo
        label.stringValue = message
        let font = label.font ?? NSFont.systemFont(ofSize: 12.5)
        let labelW = ceil((message as NSString).size(withAttributes: [.font: font]).width)
        let w = min(max(220, 15 + 16 + 9 + labelW + 14 + 46 + 13), popover.frame.width)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
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
        let leftStack = NSStackView(views: [backButton, titleLabel])
        leftStack.orientation = .horizontal
        leftStack.spacing = 5
        leftStack.alignment = .centerY
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail
        root.addSubview(leftStack)

        windowButton.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Open Skelf window")
        windowButton.imagePosition = .imageOnly
        windowButton.isBordered = false
        windowButton.focusRingType = .none
        windowButton.contentTintColor = .controlAccentColor
        windowButton.toolTip = "Open Skelf window"
        windowButton.target = self
        windowButton.action = #selector(openApp)
        windowButton.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 11.0, *) {
            windowButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        }
        root.addSubview(windowButton)

        optionsButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Options")
        optionsButton.imagePosition = .imageOnly
        optionsButton.isBordered = false
        optionsButton.focusRingType = .none
        optionsButton.contentTintColor = .controlAccentColor
        optionsButton.toolTip = "Settings & options"
        optionsButton.target = self
        optionsButton.action = #selector(showOptions)
        optionsButton.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 11.0, *) {
            optionsButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        }
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
            leftStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 13),
            leftStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: windowButton.leadingAnchor, constant: -8),
            windowButton.centerYAnchor.constraint(equalTo: leftStack.centerYAnchor),
            windowButton.trailingAnchor.constraint(equalTo: optionsButton.leadingAnchor, constant: -8),
            windowButton.widthAnchor.constraint(equalToConstant: 24),
            windowButton.heightAnchor.constraint(equalToConstant: 20),
            optionsButton.centerYAnchor.constraint(equalTo: leftStack.centerYAnchor),
            optionsButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            optionsButton.widthAnchor.constraint(equalToConstant: 24),
            optionsButton.heightAnchor.constraint(equalToConstant: 20),

            searchField.topAnchor.constraint(equalTo: leftStack.bottomAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),

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
        tw.present(message: message, below: pop) { [weak self] in self?.onUndo?() }
    }

    /// The toast lives with the menu — when the popover collapses, so does the toast.
    func dismissToast() { toastWindow?.dismiss() }

    // Size the popover to fit its content (shrink when few items; cap + scroll when many).
    private func resizeToFit() {
        view.layoutSubtreeIfNeeded()
        let topChrome: CGFloat = 75      // root top → scroll top (header + search + gaps)
        let bottomPad: CGFloat = 12
        let contentArea = contentStack.fittingSize.height + 14   // doc top(4) + bottom(10) insets
        let maxArea: CGFloat = 430
        let h = topChrome + min(maxArea, contentArea) + bottomPad
        preferredContentSize = NSSize(width: 320, height: max(140, h))
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
        folders.autoCategorize(store.skills)
        setupMainMenu()
        dlog("launched -> \(store.skills.count) skills")
        // a pin OR a folder change anywhere re-renders both the window and the popover
        let refreshAll: () -> Void = { [weak self] in
            self?.model?.bumpReload()
            self?.popoverController?.reload()
        }
        favorites.onChange = refreshAll
        folders.onChange = refreshAll
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
        folders.autoCategorize(store.skills)
        popoverController?.reload()
        model?.bumpReload()
        dlog("reload(auto: \(auto)) -> \(store.skills.count) skills")
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
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.contentViewController = host
            w.title = "Skelf"
            w.minSize = NSSize(width: 640, height: 440)
            w.setContentSize(NSSize(width: 760, height: 580))
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
