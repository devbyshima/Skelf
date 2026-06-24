// Skill model, on-disk SkillStore, FSEvents watcher, Favorites, and the folder tree.

import AppKit
import SwiftUI
import Observation
import QuartzCore
import CoreServices
import ServiceManagement
import Carbon.HIToolbox

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

    // A place skills can live. `installed` holds <id>/SKILL.md. If `enabled` is non-nil a
    // skill is "on" only when <id> also exists there (the .agents↔.claude symlink installer);
    // if nil, every skill found is on (a standard or plugin-provided skills directory).
    // `defaultSource` attributes skills with no skills-lock.json entry (e.g. the plugin or
    // marketplace folder they came from) rather than the bare "local".
    struct Root {
        let installed: URL
        let enabled: URL?
        let lock: URL?
        var defaultSource: String?

        init(installed: URL, enabled: URL?, lock: URL?, defaultSource: String? = nil) {
            self.installed = installed; self.enabled = enabled
            self.lock = lock; self.defaultSource = defaultSource
        }
    }

    // Skills live in many places: the `npx skills` installer layout, the standard Claude config
    // dir (relocatable via CLAUDE_CONFIG_DIR / XDG_CONFIG_HOME), plugin & marketplace bundles,
    // and project `.claude/skills` folders inside your code directories. Discover them all so the
    // app works for any user without configuration. Order = metadata priority (the first root to
    // hold a given skill id wins), so the rich installer layout is preferred over bare copies.
    private static var rootCache: [Root] = []
    private static var rootCacheStamp = Date.distantPast

    /// Discovered roots, cached briefly so the launch reload + watcher setup (and rapid
    /// FSEvents-triggered reloads) don't each re-crawl the disk. `reload()` always re-reads each
    /// root's contents regardless, so new skills in existing roots appear immediately; only a
    /// brand-new root waits out the cache. Manual Refresh Skills calls `invalidateRootCache()`.
    static func discoverRoots() -> [Root] {
        if !rootCache.isEmpty, Date().timeIntervalSince(rootCacheStamp) < 20 { return rootCache }
        let roots = scanRoots()
        rootCache = roots
        rootCacheStamp = Date()
        return roots
    }

    /// Drop the cached root list so the next discovery re-scans the disk.
    static func invalidateRootCache() { rootCache = []; rootCacheStamp = .distantPast }

    private static func scanRoots() -> [Root] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var roots: [Root] = []

        // 1. Explicit override + the `npx skills` installer layout (.agents/skills, with
        //    .claude/skills symlinks marking what's enabled, plus skills-lock.json).
        if let ov = ProcessInfo.processInfo.environment["SKILLS_DEV_DIR"], !ov.isEmpty {
            roots.append(installerRoot(URL(fileURLWithPath: (ov as NSString).expandingTildeInPath)))
        }
        roots.append(installerRoot(home.appendingPathComponent("Dev")))
        roots.append(installerRoot(home))

        // 2. The project Skelf was launched in, if any (installer layout or a plain .claude/skills).
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        roots.append(installerRoot(cwd))
        roots.append(Root(installed: cwd.appendingPathComponent(".claude/skills"), enabled: nil, lock: nil))

        // 3. Every Claude config base (honoring CLAUDE_CONFIG_DIR / XDG_CONFIG_HOME): its standard
        //    skills/ directory plus any plugin- or marketplace-provided skills.
        for base in configBases() {
            roots.append(Root(installed: base.appendingPathComponent("skills"), enabled: nil,
                              lock: existingFile(base.appendingPathComponent("skills-lock.json"))))
            roots.append(contentsOf: pluginRoots(under: base))
        }

        // 4. Recursively scan common code folders for project-level skills in any repo.
        roots.append(contentsOf: projectRoots())

        // Keep the order, drop duplicate scan targets, and keep only roots that exist.
        var seen = Set<String>()
        return roots.filter { root in
            let path = root.installed.standardizedFileURL.path
            guard seen.insert(path).inserted else { return false }
            return isDirectory(root.installed)
        }
    }

    /// The `npx skills` installer layout rooted at `baseDir`.
    private static func installerRoot(_ baseDir: URL) -> Root {
        Root(installed: baseDir.appendingPathComponent(".agents/skills"),
             enabled: baseDir.appendingPathComponent(".claude/skills"),
             lock: baseDir.appendingPathComponent("skills-lock.json"))
    }

    /// Claude's config base directories, most authoritative first. `CLAUDE_CONFIG_DIR` is the
    /// official relocation lever; `XDG_CONFIG_HOME/claude` and the two defaults cover the rest.
    private static func configBases() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        var bases: [URL] = []
        func add(_ url: URL) {
            let p = url.standardizedFileURL.path
            if !bases.contains(where: { $0.standardizedFileURL.path == p }) { bases.append(url) }
        }
        if let c = env["CLAUDE_CONFIG_DIR"], !c.isEmpty {
            add(URL(fileURLWithPath: (c as NSString).expandingTildeInPath))
        }
        add(home.appendingPathComponent(".claude"))
        if let x = env["XDG_CONFIG_HOME"], !x.isEmpty {
            add(URL(fileURLWithPath: (x as NSString).expandingTildeInPath).appendingPathComponent("claude"))
        }
        add(home.appendingPathComponent(".config/claude"))
        return bases
    }

    /// Skills bundled by installed plugins / marketplaces: every `skills/` directory under
    /// `<base>/plugins`, attributed to the plugin or marketplace folder it sits in.
    private static func pluginRoots(under base: URL) -> [Root] {
        let fm = FileManager.default
        let pluginsDir = base.appendingPathComponent("plugins")
        guard isDirectory(pluginsDir) else { return [] }
        var roots: [Root] = []
        var seen = Set<String>()
        var stack: [(URL, Int)] = [(pluginsDir, 0)]
        let maxDepth = 4, maxVisited = 2000
        while let (dir, depth) = stack.popLast(), seen.count < maxVisited {
            guard seen.insert(dir.resolvingSymlinksInPath().path).inserted else { continue }   // skip symlink cycles
            let children = (try? fm.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for child in children where isDirectory(child) {
                if child.lastPathComponent == "skills" {
                    roots.append(Root(installed: child, enabled: nil, lock: nil,
                                      defaultSource: pluginSource(for: child)))
                } else if depth < maxDepth {
                    stack.append((child, depth + 1))
                }
            }
        }
        return roots
    }

    /// Bounded crawl of common code directories for project skill folders (the `.agents/skills`
    /// installer layout or a plain `.claude/skills`). Skips heavy build/dependency dirs and caps
    /// the work so it stays cheap to run on launch and on every reload.
    private static func projectRoots() -> [Root] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let starts = ["Dev", "Developer", "Projects", "projects", "code", "Code", "src",
                      "work", "repos", "git", "GitHub", "Documents/GitHub"]
            .map { home.appendingPathComponent($0) }
            .filter { isDirectory($0) }
        let skip: Set<String> = ["node_modules", ".git", ".build", "build", "DerivedData",
            "Pods", ".next", "dist", "out", "target", "vendor", ".venv", "venv", ".cache",
            ".gradle", ".idea", ".svn", "__pycache__", "Carthage", ".swiftpm"]
        var roots: [Root] = []
        var seen = Set<String>()
        var stack: [(URL, Int)] = starts.map { ($0, 0) }
        let maxVisited = 3000, maxDepth = 4
        while let (dir, depth) = stack.popLast(), seen.count < maxVisited {
            guard seen.insert(dir.resolvingSymlinksInPath().path).inserted else { continue }   // skip symlink cycles
            if isDirectory(dir.appendingPathComponent(".agents/skills")) {
                roots.append(installerRoot(dir))
            } else if isDirectory(dir.appendingPathComponent(".claude/skills")) {
                roots.append(Root(installed: dir.appendingPathComponent(".claude/skills"), enabled: nil,
                                  lock: existingFile(dir.appendingPathComponent("skills-lock.json"))))
            }
            guard depth < maxDepth else { continue }
            let children = (try? fm.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
            for child in children where isDirectory(child) {
                let name = child.lastPathComponent
                // .claude/.agents are detected from their parent above; never descend into
                // hidden dirs (keeps the crawl off skill internals, .git, caches, etc.).
                if name.hasPrefix(".") || skip.contains(name) { continue }
                stack.append((child, depth + 1))
            }
        }
        return roots
    }

    /// A readable source label for a plugin/marketplace `skills/` dir: the nearest ancestor
    /// folder that names the plugin or marketplace, skipping version dirs (`1.3.0`, `v2`) and
    /// generic containers (`plugins`, `cache`, `marketplaces`, …) so cached plugins like
    /// `…/expo/1.3.0/skills` are attributed to "expo", not "1.3.0".
    private static func pluginSource(for skillsDir: URL) -> String {
        let generic: Set<String> = ["skills", "plugins", "cache", "repos", "marketplaces",
                                    "external_plugins", "plugin", "node_modules"]
        func versionLike(_ s: String) -> Bool {
            let core = s.hasPrefix("v") ? String(s.dropFirst()) : s
            let head = core.split(separator: "-").first.map(String.init) ?? core
            return !head.isEmpty && head.contains(where: \.isNumber)
                && head.allSatisfy { $0.isNumber || $0 == "." }
        }
        var url = skillsDir.deletingLastPathComponent()
        for _ in 0..<6 {
            let name = url.lastPathComponent
            guard !name.isEmpty, name != "/" else { break }
            if !generic.contains(name) && !versionLike(name) { return name }
            url = url.deletingLastPathComponent()
        }
        return "local"   // pathological all-generic/version ancestry — avoid a junk label
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func existingFile(_ url: URL) -> URL? {
        FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // Directories the FSEvents watcher should follow for live add/remove/enable changes.
    static func watchPaths() -> [String] {
        discoverRoots().flatMap { [$0.installed.path] + ($0.enabled.map { [$0.path] } ?? []) }
    }

    func reload() {
        let fm = FileManager.default
        let dateFmt = DateFormatter(); dateFmt.dateFormat = "yyyy-MM-dd"
        var byId: [String: Skill] = [:]
        for root in Self.discoverRoots() {
            let lock = root.lock.map { Self.parseLock($0) } ?? [:]
            let dirs = (try? fm.contentsOfDirectory(at: root.installed,
                            includingPropertiesForKeys: [.isDirectoryKey],
                            options: [.skipsHiddenFiles])) ?? []
            for dir in dirs {
                let id = dir.lastPathComponent
                let md = dir.appendingPathComponent("SKILL.md")
                guard fm.fileExists(atPath: md.path) else { continue }
                let enabled = root.enabled == nil ? true
                            : fm.fileExists(atPath: root.enabled!.appendingPathComponent(id).path)
                // First root to hold a skill wins — but a disabled copy in a high-priority root
                // must not mask the same skill found enabled in a later one.
                if let existing = byId[id], existing.enabled || !enabled { continue }
                let frontmatter = Self.parseFrontmatter(md)
                let meta = lock[id]
                let files = (try? fm.contentsOfDirectory(atPath: dir.path))?.count ?? 1
                var installed = "—"
                if let attrs = try? fm.attributesOfItem(atPath: dir.path), let d = attrs[.modificationDate] as? Date {
                    installed = dateFmt.string(from: d)
                }
                byId[id] = Skill(
                    id: id,
                    name: frontmatter.name ?? id,
                    description: frontmatter.description ?? "",
                    version: frontmatter.version,
                    source: meta?.source ?? root.defaultSource ?? "local",
                    category: Self.category(fromPath: meta?.skillPath ?? id),
                    skillPath: meta?.skillPath ?? "\(id)/SKILL.md",
                    enabled: enabled,
                    fileCount: files,
                    installedAt: installed,
                    dirPath: dir.path
                )
            }
        }
        skills = byId.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func parseFrontmatter(_ url: URL) -> (name: String?, description: String?, version: String?) {
        var name: String?, desc: String?, version: String?
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
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
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
    /// Every real folder in the tree (root excluded), name-sorted — for global search.
    func allFolders() -> [Node] {
        nodes.values.filter { $0.id != rootId }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

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
// The special "Favorites" folder is virtual (not a real FolderStore.Node) — it gathers
// every favorited skill and is shown first on the home grid with a distinct look.
let favoritesFolderId = "__favorites__"
