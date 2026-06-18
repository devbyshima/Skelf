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
// Pure AppKit (no SwiftUI) so it compiles with the Command Line Tools toolchain.
// Build:  ./build.sh        Run:  open SkillShelf.app

import AppKit
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
}

// A row in the folder-navigating grid: a sub-folder or a skill.
enum GridEntry {
    case folder(FolderStore.Node)
    case skill(Skill)
}

// Drag-and-drop payload type for grid items ("skill:<id>" / "folder:<id>").
let skelfEntryType = NSPasteboard.PasteboardType("dev.fulltime.skelf.entry")

// A breadcrumb that's also a drop target — drag a skill/folder onto it to move it up.
final class CrumbButton: NSButton {
    var folderId = ""
    var onDropEntry: ((String, String) -> Bool)?

    func enableDrops() { registerForDraggedTypes([skelfEntryType]) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.availableType(from: [skelfEntryType]) != nil else { return [] }
        dropHighlight(true)
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropHighlight(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight(false)
        guard let s = sender.draggingPasteboard.pasteboardItems?.first?.string(forType: skelfEntryType) else { return false }
        return onDropEntry?(s, folderId) ?? false
    }
    private func dropHighlight(_ on: Bool) {
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = on ? NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor : NSColor.clear.cgColor
    }
}

// Payload carried by context-menu items (move/copy targets).
final class CtxPayload {
    let skillId: String?
    let folderId: String?
    let source: String?
    let target: String
    let copy: Bool
    init(skillId: String? = nil, folderId: String? = nil, source: String? = nil, target: String, copy: Bool = false) {
        self.skillId = skillId; self.folderId = folderId; self.source = source; self.target = target; self.copy = copy
    }
}

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

// A Liquid Glass card whose corners are concentric with their container (macOS 27).
final class GlassCardView: NSGlassEffectView {
    @available(macOS 27.0, *)
    override var cornerConfiguration: NSViewCornerConfiguration? {
        .uniformCorners(radius: .containerConcentric(10))
    }
}

// MARK: - Grid tile

final class SkillGridItem: NSCollectionViewItem {
    private let card = NSView()
    private let glyph = NSView()
    private let initialsLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let menuButton = NSButton()
    private let starButton = NSButton()
    private let gradient = CAGradientLayer()
    var onToggleFavorite: (() -> Void)?
    var onMenu: ((NSView) -> Void)?

    override func loadView() {
        let root = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(card)

        glyph.wantsLayer = true
        glyph.translatesAutoresizingMaskIntoConstraints = false
        gradient.frame = CGRect(x: 0, y: 0, width: 52, height: 52)
        gradient.cornerRadius = 13
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        glyph.layer?.addSublayer(gradient)
        card.addSubview(glyph)

        initialsLabel.font = .systemFont(ofSize: 19, weight: .bold)
        initialsLabel.textColor = .white
        initialsLabel.alignment = .center
        initialsLabel.translatesAutoresizingMaskIntoConstraints = false
        glyph.addSubview(initialsLabel)

        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 2
        nameLabel.cell?.usesSingleLineMode = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(nameLabel)

        metaLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.alignment = .center
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(metaLabel)

        menuButton.isBordered = false
        menuButton.bezelStyle = .regularSquare
        menuButton.imageScaling = .scaleProportionallyDown
        menuButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")
        menuButton.contentTintColor = .tertiaryLabelColor
        menuButton.focusRingType = .none
        menuButton.target = self
        menuButton.action = #selector(menuClicked)
        menuButton.toolTip = "Organize (move, copy, …)"
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(menuButton)

        starButton.isBordered = false
        starButton.bezelStyle = .regularSquare
        starButton.imageScaling = .scaleProportionallyDown
        starButton.focusRingType = .none
        starButton.target = self
        starButton.action = #selector(starClicked)
        starButton.toolTip = "Pin to favorites"
        starButton.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(starButton)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: root.topAnchor),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            starButton.topAnchor.constraint(equalTo: card.topAnchor, constant: 7),
            starButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 7),
            starButton.widthAnchor.constraint(equalToConstant: 18),
            starButton.heightAnchor.constraint(equalToConstant: 18),
            glyph.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            glyph.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 52),
            glyph.heightAnchor.constraint(equalToConstant: 52),
            initialsLabel.centerXAnchor.constraint(equalTo: glyph.centerXAnchor),
            initialsLabel.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            nameLabel.topAnchor.constraint(equalTo: glyph.bottomAnchor, constant: 10),
            nameLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 7),
            nameLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -7),
            metaLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            metaLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 6),
            metaLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
            menuButton.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            menuButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
            menuButton.widthAnchor.constraint(equalToConstant: 18),
            menuButton.heightAnchor.constraint(equalToConstant: 18),
        ])
        root.addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
        view = root
    }

    private var hovering = false

    func configure(_ skill: Skill, isFavorite: Bool) {
        initialsLabel.stringValue = Palette.initials(skill.name)
        nameLabel.stringValue = skill.name
        metaLabel.stringValue = skill.enabled ? skill.initiator : "\(skill.initiator) · off"
        gradient.colors = Palette.gradientColors(skill.name)
        hovering = false
        applyHoverAndBorder(animated: false)
        view.alphaValue = skill.enabled ? 1.0 : 0.55
        view.toolTip = "\(skill.initiator)\n\n\(skill.description)"
        starButton.image = NSImage(systemSymbolName: isFavorite ? "star.fill" : "star",
                                   accessibilityDescription: isFavorite ? "Favorited" : "Add to favorites")
        starButton.contentTintColor = isFavorite ? .systemYellow : .tertiaryLabelColor
        starButton.toolTip = isFavorite ? "Unpin from favorites" : "Pin to favorites"
    }

    @objc private func starClicked() { onToggleFavorite?() }
    @objc private func menuClicked() { onMenu?(menuButton) }

    func pressPop() { springPop(card.layer, from: 0.93) }

    override func mouseEntered(with event: NSEvent) { hovering = true; applyHoverAndBorder(animated: true) }
    override func mouseExited(with event: NSEvent) { hovering = false; applyHoverAndBorder(animated: true) }

    private func applyHoverAndBorder(animated: Bool) {
        let apply = {
            self.card.layer?.backgroundColor = (self.hovering
                ? NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.55)
                : NSColor.controlBackgroundColor).cgColor
            let border: NSColor = self.isSelected ? .controlAccentColor
                : (self.hovering ? NSColor.controlAccentColor.withAlphaComponent(0.5) : .separatorColor)
            self.card.layer?.borderColor = border.cgColor
            self.card.layer?.borderWidth = self.isSelected ? 2 : 1
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.13; ctx.allowsImplicitAnimation = true; apply() }
        } else { apply() }
    }
    override var isSelected: Bool { didSet { applyHoverAndBorder(animated: true) } }
}

// MARK: - Folder tile

final class FolderGridItem: NSCollectionViewItem {
    private let card = NSView()
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let menuButton = NSButton()
    var onMenu: ((NSView) -> Void)?

    override func loadView() {
        let root = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(card)

        icon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
        icon.contentTintColor = .controlAccentColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(icon)

        menuButton.isBordered = false
        menuButton.bezelStyle = .regularSquare
        menuButton.imageScaling = .scaleProportionallyDown
        menuButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")
        menuButton.contentTintColor = .tertiaryLabelColor
        menuButton.focusRingType = .none
        menuButton.target = self
        menuButton.action = #selector(menuClicked)
        menuButton.toolTip = "Folder options (rename, move, …)"
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(menuButton)

        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 2
        nameLabel.cell?.usesSingleLineMode = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(nameLabel)

        countLabel.font = .systemFont(ofSize: 10)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .center
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(countLabel)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: root.topAnchor),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            icon.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 46),
            icon.heightAnchor.constraint(equalToConstant: 46),
            nameLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 10),
            nameLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 7),
            nameLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -7),
            countLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            countLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 6),
            countLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
            menuButton.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            menuButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
            menuButton.widthAnchor.constraint(equalToConstant: 18),
            menuButton.heightAnchor.constraint(equalToConstant: 18),
        ])
        root.addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
        view = root
    }

    private var hovering = false

    func configure(_ node: FolderStore.Node) {
        nameLabel.stringValue = node.name
        let s = node.skills.count, f = node.folders.count
        var parts: [String] = []
        if f > 0 { parts.append("\(f) folder\(f == 1 ? "" : "s")") }
        parts.append("\(s) skill\(s == 1 ? "" : "s")")
        countLabel.stringValue = parts.joined(separator: " · ")
        hovering = false
        applyHoverAndBorder(animated: false)
        view.toolTip = node.name
    }

    @objc private func menuClicked() { onMenu?(menuButton) }

    func pressPop() { springPop(card.layer, from: 0.93) }

    override func mouseEntered(with event: NSEvent) { hovering = true; applyHoverAndBorder(animated: true) }
    override func mouseExited(with event: NSEvent) { hovering = false; applyHoverAndBorder(animated: true) }

    private func applyHoverAndBorder(animated: Bool) {
        let apply = {
            self.card.layer?.backgroundColor = (self.hovering
                ? NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.55)
                : NSColor.controlBackgroundColor).cgColor
            let border: NSColor = self.isSelected ? .controlAccentColor
                : (self.hovering ? NSColor.controlAccentColor.withAlphaComponent(0.5) : .separatorColor)
            self.card.layer?.borderColor = border.cgColor
            self.card.layer?.borderWidth = self.isSelected ? 2 : 1
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.13; ctx.allowsImplicitAnimation = true; apply() }
        } else { apply() }
    }
    override var isSelected: Bool { didSet { applyHoverAndBorder(animated: true) } }
}

// MARK: - Detail screen

final class SkillDetailView: NSView {
    var onBack: (() -> Void)?
    var onCopy: ((Skill) -> Void)?
    var onToggleFavorite: ((Skill) -> Void)?
    var onOrganize: ((Skill, NSView) -> Void)?
    private var skill: Skill?

    private let favoriteButton = NSButton()
    private let folderButton = NSButton()
    private let glyph = NSView()
    private let gradient = CAGradientLayer()
    private let initialsLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusPill = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let copiedLabel = NSTextField(labelWithString: "")
    private let descLabel = NSTextField(wrappingLabelWithString: "")
    private let metaStack = NSStackView()
    private var copiedWork: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func styleSecondaryButton(_ b: NSButton, _ title: String) {
        b.title = title
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.translatesAutoresizingMaskIntoConstraints = false
    }

    private func build() {
        // top bar with a back button
        let back = NSButton(title: "‹  All skills", target: self, action: #selector(backTapped))
        back.bezelStyle = .recessed
        back.isBordered = false
        back.contentTintColor = .controlAccentColor
        back.font = .systemFont(ofSize: 13, weight: .medium)
        back.translatesAutoresizingMaskIntoConstraints = false
        addSubview(back)

        let topDivider = NSBox(); topDivider.boxType = .separator
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topDivider)

        // scroll area
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

        // hero
        glyph.wantsLayer = true
        glyph.translatesAutoresizingMaskIntoConstraints = false
        gradient.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        gradient.cornerRadius = 15
        gradient.startPoint = CGPoint(x: 0, y: 0); gradient.endPoint = CGPoint(x: 1, y: 1)
        glyph.layer?.addSublayer(gradient)
        initialsLabel.font = .systemFont(ofSize: 24, weight: .bold)
        initialsLabel.textColor = .white
        initialsLabel.alignment = .center
        initialsLabel.translatesAutoresizingMaskIntoConstraints = false
        glyph.addSubview(initialsLabel)
        doc.addSubview(glyph)

        nameLabel.font = .systemFont(ofSize: 22, weight: .bold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(nameLabel)

        statusPill.font = .systemFont(ofSize: 11, weight: .semibold)
        statusPill.wantsLayer = true
        statusPill.drawsBackground = false
        statusPill.alignment = .center
        statusPill.layer?.cornerRadius = 9
        statusPill.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(statusPill)

        copyButton.isBordered = false
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .large
        copyButton.keyEquivalent = "\r"
        copyButton.font = .systemFont(ofSize: 14, weight: .semibold)
        copyButton.contentTintColor = .white
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        // Interactive Liquid Glass: the pill subtly bounces when clicked (macOS 27).
        let copyGlass = NSGlassEffectView()
        copyGlass.cornerRadius = 18
        copyGlass.tintColor = .controlAccentColor
        copyGlass.contentView = copyButton
        copyGlass.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 27.0, *) { copyGlass.effectIsInteractive = true }
        doc.addSubview(copyGlass)

        copiedLabel.stringValue = "Copied to clipboard ✓"
        copiedLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        copiedLabel.textColor = .systemGreen
        copiedLabel.isHidden = true
        copiedLabel.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(copiedLabel)

        // secondary actions
        let revealBtn = NSButton(title: "Reveal SKILL.md", target: self, action: #selector(revealTapped))
        styleSecondaryButton(revealBtn, "Reveal SKILL.md")
        let githubBtn = NSButton(title: "View on GitHub ↗", target: self, action: #selector(githubTapped))
        styleSecondaryButton(githubBtn, "View on GitHub ↗")
        favoriteButton.target = self
        favoriteButton.action = #selector(favoriteTapped)
        styleSecondaryButton(favoriteButton, "☆ Favorite")
        folderButton.target = self
        folderButton.action = #selector(organizeTapped)
        styleSecondaryButton(folderButton, "Add to folder ▾")
        let actions = NSStackView(views: [favoriteButton, folderButton, revealBtn, githubBtn])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(actions)

        // meta + description stack
        metaStack.orientation = .vertical
        metaStack.alignment = .leading
        metaStack.spacing = 9
        metaStack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(metaStack)

        let descHeader = NSTextField(labelWithString: "DESCRIPTION")
        descHeader.font = .systemFont(ofSize: 10, weight: .semibold)
        descHeader.textColor = .tertiaryLabelColor
        descHeader.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(descHeader)

        descLabel.font = .systemFont(ofSize: 13)
        descLabel.textColor = .labelColor
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(descLabel)

        NSLayoutConstraint.activate([
            back.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            back.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            topDivider.topAnchor.constraint(equalTo: back.bottomAnchor, constant: 8),
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

            glyph.topAnchor.constraint(equalTo: doc.topAnchor, constant: 22),
            glyph.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 24),
            glyph.widthAnchor.constraint(equalToConstant: 64),
            glyph.heightAnchor.constraint(equalToConstant: 64),
            initialsLabel.centerXAnchor.constraint(equalTo: glyph.centerXAnchor),
            initialsLabel.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),

            nameLabel.topAnchor.constraint(equalTo: glyph.topAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 16),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -24),

            statusPill.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 8),
            statusPill.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            statusPill.heightAnchor.constraint(equalToConstant: 20),

            copyGlass.topAnchor.constraint(equalTo: glyph.bottomAnchor, constant: 22),
            copyGlass.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 24),
            copyGlass.heightAnchor.constraint(equalToConstant: 38),
            copyGlass.widthAnchor.constraint(greaterThanOrEqualToConstant: 230),
            copiedLabel.centerYAnchor.constraint(equalTo: copyGlass.centerYAnchor),
            copiedLabel.leadingAnchor.constraint(equalTo: copyGlass.trailingAnchor, constant: 14),

            actions.topAnchor.constraint(equalTo: copyGlass.bottomAnchor, constant: 12),
            actions.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 24),

            metaStack.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 20),
            metaStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 24),
            metaStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -24),

            descHeader.topAnchor.constraint(equalTo: metaStack.bottomAnchor, constant: 20),
            descHeader.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 24),
            descLabel.topAnchor.constraint(equalTo: descHeader.bottomAnchor, constant: 6),
            descLabel.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 24),
            descLabel.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -24),
            descLabel.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -24),
        ])
    }

    private func metaRow(_ key: String, _ value: String) -> NSView {
        let k = NSTextField(labelWithString: key.uppercased())
        k.font = .systemFont(ofSize: 10, weight: .semibold)
        k.textColor = .tertiaryLabelColor
        k.translatesAutoresizingMaskIntoConstraints = false
        k.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let v = NSTextField(labelWithString: value)
        v.font = .systemFont(ofSize: 12)
        v.textColor = .labelColor
        v.lineBreakMode = .byTruncatingMiddle
        v.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [k, v])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .firstBaseline
        return row
    }

    func configure(_ skill: Skill, isFavorite: Bool) {
        self.skill = skill
        copiedLabel.isHidden = true
        initialsLabel.stringValue = Palette.initials(skill.name)
        nameLabel.stringValue = skill.name
        gradient.colors = Palette.gradientColors(skill.name)

        favoriteButton.title = isFavorite ? "★ Favorited" : "☆ Favorite"
        favoriteButton.contentTintColor = isFavorite ? .systemYellow : nil

        statusPill.stringValue = skill.enabled ? "  ●  Enabled  " : "  ○  Installed · off  "
        statusPill.textColor = skill.enabled ? .systemGreen : .secondaryLabelColor
        statusPill.layer?.backgroundColor = (skill.enabled ? NSColor.systemGreen : NSColor.systemGray)
            .withAlphaComponent(0.16).cgColor

        copyButton.title = "Copy  \(skill.initiator)"

        metaStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        metaStack.addArrangedSubview(metaRow("Initiator", skill.initiator))
        metaStack.addArrangedSubview(metaRow("Source", skill.source))
        metaStack.addArrangedSubview(metaRow("Category", skill.category))
        metaStack.addArrangedSubview(metaRow("Version", skill.version ?? "unversioned"))
        metaStack.addArrangedSubview(metaRow("Installed", skill.installedAt))
        metaStack.addArrangedSubview(metaRow("Files", "\(skill.fileCount)"))
        metaStack.addArrangedSubview(metaRow("Path", skill.skillPath))

        descLabel.stringValue = skill.description.isEmpty ? "No description in SKILL.md." : skill.description
    }

    @objc private func backTapped() { onBack?() }

    @objc private func favoriteTapped() {
        guard let skill = skill else { return }
        onToggleFavorite?(skill)
    }

    @objc private func organizeTapped() {
        guard let skill = skill else { return }
        onOrganize?(skill, folderButton)
    }

    @objc private func copyTapped() {
        guard let skill = skill else { return }
        onCopy?(skill)
        copiedLabel.isHidden = false
        copiedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.copiedLabel.isHidden = true }
        copiedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
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

// MARK: - Window content (grid + detail navigation)

final class SkillsViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate,
                                  NSSearchFieldDelegate {
    private let store: SkillStore
    private let favorites: Favorites
    private let folders: FolderStore
    private let onCopy: (Skill) -> Void

    private var entries: [GridEntry] = []
    private var currentFolderId: String
    private var filterMode = 0
    private var query = ""
    private var detailSkill: Skill?

    // internal cut/copy clipboard (for paste-into-current-folder)
    private struct Clip { let id: String; let isFolder: Bool; let cut: Bool; let source: String; let name: String }
    private var clip: Clip?

    private let searchField = NSSearchField()
    private let filterSeg = NSSegmentedControl(labels: ["All", "Enabled", "Off"],
                                               trackingMode: .selectOne, target: nil, action: nil)
    private let collectionView = NSCollectionView()
    private let gridScroll = NSScrollView()
    private let bar = NSView()
    private let crumbBar = NSView()
    private let crumbStack = NSStackView()
    private let pasteButton = NSButton()
    private let newFolderButton = NSButton()
    private let topDivider = NSBox()
    private let crumbDivider = NSBox()
    private let detailView = SkillDetailView(frame: .zero)

    private let skillItemID = NSUserInterfaceItemIdentifier("SkillGridItem")
    private let folderItemID = NSUserInterfaceItemIdentifier("FolderGridItem")

    init(store: SkillStore, favorites: Favorites, folders: FolderStore, onCopy: @escaping (Skill) -> Void) {
        self.store = store
        self.favorites = favorites
        self.folders = folders
        self.currentFolderId = folders.rootId
        self.onCopy = onCopy
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 580)) }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()          // initial state is the grid (detailView starts hidden); no transition animation here
        applyFilter()
    }

    func openDetail(id: String) {
        if let s = store.skills.first(where: { $0.id == id }) { showDetail(s) }
    }

    func enterFolder(id: String) {
        if folders.node(id) != nil { navigate(to: id) }
    }

    func refreshFromStore(auto: Bool = false) {
        if folders.node(currentFolderId) == nil { currentFolderId = folders.rootId }  // current folder was deleted
        applyFilter()
        if !detailView.isHidden, let id = detailSkill?.id,
           let fresh = store.skills.first(where: { $0.id == id }) {
            detailSkill = fresh
            detailView.configure(fresh, isFavorite: favorites.isFavorite(id))
        }
    }

    private func buildUI() {
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search this folder…"
        searchField.delegate = self
        bar.addSubview(searchField)

        filterSeg.translatesAutoresizingMaskIntoConstraints = false
        filterSeg.selectedSegment = 0
        filterSeg.target = self
        filterSeg.action = #selector(filterChanged)
        bar.addSubview(filterSeg)

        topDivider.boxType = .separator
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topDivider)

        // breadcrumb bar
        crumbBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(crumbBar)
        crumbStack.orientation = .horizontal
        crumbStack.spacing = 4
        crumbStack.alignment = .centerY
        crumbStack.translatesAutoresizingMaskIntoConstraints = false
        crumbBar.addSubview(crumbStack)
        pasteButton.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Paste")
        pasteButton.imagePosition = .imageLeading
        pasteButton.bezelStyle = .rounded
        pasteButton.controlSize = .small
        pasteButton.target = self
        pasteButton.action = #selector(pasteTapped)
        pasteButton.isHidden = true
        pasteButton.translatesAutoresizingMaskIntoConstraints = false
        crumbBar.addSubview(pasteButton)
        newFolderButton.title = "New Folder"
        newFolderButton.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "New Folder")
        newFolderButton.imagePosition = .imageLeading
        newFolderButton.bezelStyle = .rounded
        newFolderButton.controlSize = .small
        newFolderButton.target = self
        newFolderButton.action = #selector(newFolderTapped)
        newFolderButton.translatesAutoresizingMaskIntoConstraints = false
        crumbBar.addSubview(newFolderButton)

        crumbDivider.boxType = .separator
        crumbDivider.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(crumbDivider)

        gridScroll.translatesAutoresizingMaskIntoConstraints = false
        gridScroll.hasVerticalScroller = true
        gridScroll.borderType = .noBorder
        gridScroll.drawsBackground = false
        view.addSubview(gridScroll)

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 150, height: 132)
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 16
        layout.sectionInset = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
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
        gridScroll.documentView = collectionView

        detailView.translatesAutoresizingMaskIntoConstraints = false
        detailView.onBack = { [weak self] in self?.showGrid() }
        detailView.onCopy = { [weak self] skill in self?.didCopy(skill) }
        detailView.onToggleFavorite = { [weak self] skill in self?.favorites.toggle(skill.id) }
        detailView.onOrganize = { [weak self] skill, anchor in self?.showCopyToFolderMenu(skill, anchor: anchor) }
        detailView.isHidden = true
        view.addSubview(detailView)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 46),

            filterSeg.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            filterSeg.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            filterSeg.widthAnchor.constraint(equalToConstant: 180),
            searchField.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            searchField.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: filterSeg.leadingAnchor, constant: -10),

            topDivider.topAnchor.constraint(equalTo: bar.bottomAnchor),
            topDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            crumbBar.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            crumbBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            crumbBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            crumbBar.heightAnchor.constraint(equalToConstant: 36),
            crumbStack.leadingAnchor.constraint(equalTo: crumbBar.leadingAnchor, constant: 12),
            crumbStack.centerYAnchor.constraint(equalTo: crumbBar.centerYAnchor),
            crumbStack.trailingAnchor.constraint(lessThanOrEqualTo: pasteButton.leadingAnchor, constant: -8),
            pasteButton.trailingAnchor.constraint(equalTo: newFolderButton.leadingAnchor, constant: -8),
            pasteButton.centerYAnchor.constraint(equalTo: crumbBar.centerYAnchor),
            newFolderButton.trailingAnchor.constraint(equalTo: crumbBar.trailingAnchor, constant: -12),
            newFolderButton.centerYAnchor.constraint(equalTo: crumbBar.centerYAnchor),

            crumbDivider.topAnchor.constraint(equalTo: crumbBar.bottomAnchor),
            crumbDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            crumbDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            gridScroll.topAnchor.constraint(equalTo: crumbDivider.bottomAnchor),
            gridScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gridScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gridScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            detailView.topAnchor.constraint(equalTo: view.topAnchor),
            detailView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            detailView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            detailView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        rebuildCrumbs()
    }

    // --- breadcrumb ---

    private func rebuildCrumbs() {
        crumbStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let nodes = folders.path(to: currentFolderId)
        for (i, node) in nodes.enumerated() {
            if i > 0 {
                let sep = NSTextField(labelWithString: "›")
                sep.textColor = .tertiaryLabelColor
                sep.font = .systemFont(ofSize: 13)
                crumbStack.addArrangedSubview(sep)
            }
            let isCurrent = (i == nodes.count - 1)
            if isCurrent {
                let lbl = NSTextField(labelWithString: node.name)
                lbl.font = .systemFont(ofSize: 13, weight: .semibold)
                lbl.toolTip = node.id == folders.rootId ? nil : "Double-click to rename"
                if node.id != folders.rootId {
                    let g = NSClickGestureRecognizer(target: self, action: #selector(renameCurrent))
                    g.numberOfClicksRequired = 2
                    lbl.addGestureRecognizer(g)
                }
                crumbStack.addArrangedSubview(lbl)
            } else {
                let btn = CrumbButton(title: node.name, target: self, action: #selector(crumbTapped(_:)))
                btn.isBordered = false
                btn.contentTintColor = .controlAccentColor
                btn.font = .systemFont(ofSize: 13)
                btn.tag = i
                btn.folderId = node.id
                btn.toolTip = "Drop a skill or folder here to move it to “\(node.name)”"
                btn.enableDrops()
                btn.onDropEntry = { [weak self] payload, target in self?.handleCrumbDrop(payload, into: target) ?? false }
                crumbStack.addArrangedSubview(btn)
            }
        }
    }

    private func handleCrumbDrop(_ payload: String, into folderId: String) -> Bool {
        let comps = payload.split(separator: ":", maxSplits: 1).map(String.init)
        guard comps.count == 2 else { return false }
        if comps[0] == "folder" {
            guard comps[1] != folderId, !folders.isDescendant(folderId, of: comps[1]) else { return false }
            folders.moveFolder(comps[1], to: folderId)
        } else {
            folders.moveSkill(comps[1], from: currentFolderId, to: folderId)
        }
        return true
    }

    @objc private func crumbTapped(_ sender: NSButton) {
        let nodes = folders.path(to: currentFolderId)
        if sender.tag >= 0, sender.tag < nodes.count { navigate(to: nodes[sender.tag].id) }
    }

    @objc private func renameCurrent() {
        guard currentFolderId != folders.rootId, let node = folders.node(currentFolderId) else { return }
        promptText("Rename folder", node.name) { [weak self] name in
            guard let self = self else { return }
            self.folders.rename(self.currentFolderId, to: name)
        }
    }

    private func navigate(to id: String) {
        currentFolderId = id
        rebuildCrumbs()
        applyFilter()
        showGrid()
    }

    // --- navigation between grid / detail ---

    private var showingDetail = false

    private func showGrid() {
        detailSkill = nil
        showingDetail = false
        bar.isHidden = false; topDivider.isHidden = false; gridScroll.isHidden = false
        crumbBar.isHidden = false; crumbDivider.isHidden = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16; ctx.allowsImplicitAnimation = true
            self.detailView.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, !self.showingDetail else { return }
            self.detailView.isHidden = true
            self.collectionView.deselectAll(nil)
        })
    }

    private func showDetail(_ skill: Skill) {
        detailSkill = skill
        showingDetail = true
        detailView.configure(skill, isFavorite: favorites.isFavorite(skill.id))
        detailView.alphaValue = 0
        detailView.isHidden = false
        detailView.wantsLayer = true
        // morph in: spring-scale up from the tile while fading (zoom-through feel)
        if let l = detailView.layer, l.bounds.width > 1 {
            let spring = CASpringAnimation(keyPath: "transform")
            spring.fromValue = centerScale(l, 0.96)
            spring.toValue = CATransform3DIdentity
            spring.damping = 16; spring.stiffness = 240; spring.mass = 1
            spring.duration = spring.settlingDuration
            l.add(spring, forKey: "morph")
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2; ctx.allowsImplicitAnimation = true
            self.detailView.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            guard let self = self, self.showingDetail else { return }
            self.bar.isHidden = true; self.topDivider.isHidden = true; self.gridScroll.isHidden = true
            self.crumbBar.isHidden = true; self.crumbDivider.isHidden = true
        })
    }

    // --- entries (folders + skills of the current folder) ---

    private func applyFilter() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var e: [GridEntry] = []
        for f in folders.childFolders(of: currentFolderId) where q.isEmpty || f.name.lowercased().contains(q) {
            e.append(.folder(f))
        }
        let here = folders.skillIds(in: currentFolderId).compactMap { id in store.skills.first { $0.id == id } }
        let matched = here.filter { s in
            let passFilter = filterMode == 0 || (filterMode == 1 && s.enabled) || (filterMode == 2 && !s.enabled)
            let passQuery = q.isEmpty
                || s.name.lowercased().contains(q)
                || s.description.lowercased().contains(q)
                || s.category.lowercased().contains(q)
                || s.source.lowercased().contains(q)
            return passFilter && passQuery
        }
        for s in favorites.ordered(matched) { e.append(.skill(s)) }
        entries = e
        collectionView.reloadData()
    }

    private func didCopy(_ skill: Skill) { onCopy(skill) }

    @objc private func filterChanged() { filterMode = filterSeg.selectedSegment; applyFilter() }
    func controlTextDidChange(_ obj: Notification) { query = searchField.stringValue; applyFilter() }

    // --- collection data (folders + skills) ---

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard indexPath.item < entries.count else {
            return cv.makeItem(withIdentifier: skillItemID, for: indexPath)
        }
        switch entries[indexPath.item] {
        case .folder(let node):
            let item = cv.makeItem(withIdentifier: folderItemID, for: indexPath)
            if let folder = item as? FolderGridItem {
                folder.configure(node)
                folder.onMenu = { [weak self] anchor in
                    guard let self = self else { return }
                    self.popMenu(self.folderMenu(node), at: anchor)
                }
            }
            item.view.menu = folderMenu(node)   // right-click parity
            return item
        case .skill(let skill):
            let item = cv.makeItem(withIdentifier: skillItemID, for: indexPath)
            if let grid = item as? SkillGridItem {
                grid.configure(skill, isFavorite: favorites.isFavorite(skill.id))
                grid.onToggleFavorite = { [weak self] in self?.favorites.toggle(skill.id) }
                grid.onMenu = { [weak self] anchor in
                    guard let self = self else { return }
                    self.popMenu(self.skillMenu(skill), at: anchor)
                }
            }
            item.view.menu = skillMenu(skill)   // right-click parity
            return item
        }
    }

    private func popMenu(_ menu: NSMenu, at anchor: NSView) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 2), in: anchor)
    }

    func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        if let ip = indexPaths.first, ip.item < entries.count {
            (cv.item(at: ip) as? SkillGridItem)?.pressPop()      // squash & stretch on press
            (cv.item(at: ip) as? FolderGridItem)?.pressPop()
            switch entries[ip.item] {
            case .folder(let node): navigate(to: node.id)
            case .skill(let skill): showDetail(skill)
            }
        }
        cv.deselectItems(at: indexPaths)
    }

    // --- drag & drop / reorder ---

    func collectionView(_ cv: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        // Dragging reorders/moves stored order — only meaningful with no search/filter.
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
        // Dropping ON a folder tile = move into that folder; ON a skill = reorder before it.
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
            if isFolder { folders.moveFolder(draggedId, to: target.id) }
            else { folders.moveSkill(draggedId, from: currentFolderId, to: target.id) }
            return true
        }
        // reorder within the current folder, inserting before the next same-kind item
        let anchor = anchorId(forKind: isFolder, atEntryIndex: indexPath.item)
        if isFolder { folders.reorderFolder(draggedId, in: currentFolderId, before: anchor) }
        else { folders.reorderSkill(draggedId, in: currentFolderId, before: anchor) }
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
        return nil   // append to the end of its array
    }

    // --- folder operations ---

    @objc private func newFolderTapped() {
        promptText("New folder name", "New Folder") { [weak self] name in
            guard let self = self else { return }
            self.folders.createFolder(name: name, in: self.currentFolderId)
        }
    }

    private func promptText(_ title: String, _ def: String, _ done: @escaping (String) -> Void) {
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

    // --- context menus ---

    private func mi(_ title: String, _ sel: Selector, _ rep: Any?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self; item.representedObject = rep
        return item
    }

    private func skillMenu(_ skill: Skill) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(mi("Open", #selector(ctxOpenSkill(_:)), skill.id))
        menu.addItem(mi("Copy Slash Command", #selector(ctxCopySkill(_:)), skill.id))
        menu.addItem(.separator())
        menu.addItem(mi("Cut", #selector(ctxCutSkill(_:)), skill.id))
        menu.addItem(mi("Copy", #selector(ctxCopySkillToClip(_:)), skill.id))
        if currentFolderId != folders.rootId {
            menu.addItem(.separator())
            menu.addItem(mi("Remove from “\(currentFolderName())”", #selector(ctxRemoveSkill(_:)), skill.id))
        }
        return menu
    }

    private func folderMenu(_ node: FolderStore.Node) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(mi("Open", #selector(ctxOpenFolder(_:)), node.id))
        menu.addItem(mi("Rename…", #selector(ctxRenameFolder(_:)), node.id))
        menu.addItem(mi("New Folder Inside…", #selector(ctxNewSubfolder(_:)), node.id))
        menu.addItem(.separator())
        menu.addItem(mi("Cut", #selector(ctxCutFolder(_:)), node.id))
        menu.addItem(.separator())
        menu.addItem(mi("Delete Folder", #selector(ctxDeleteFolder(_:)), node.id))
        return menu
    }

    private func currentFolderName() -> String { folders.node(currentFolderId)?.name ?? "folder" }

    /// Build a menu mirroring the folder tree; selecting a folder fires ctxApply with the payload.
    private func folderTreeMenu(exclude: String? = nil, makePayload: @escaping (String) -> CtxPayload) -> NSMenu {
        let menu = NSMenu()
        func add(_ id: String, _ depth: Int) {
            guard let node = folders.node(id), id != exclude else { return }
            let title = String(repeating: "    ", count: depth) + (id == folders.rootId ? "All Skills" : node.name)
            let item = NSMenuItem(title: title, action: #selector(ctxApply(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = makePayload(id)
            menu.addItem(item)
            for c in node.folders { add(c, depth + 1) }
        }
        add(folders.rootId, 0)
        return menu
    }

    private func showCopyToFolderMenu(_ skill: Skill, anchor: NSView) {
        let menu = folderTreeMenu { CtxPayload(skillId: skill.id, target: $0, copy: true) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    @objc private func ctxOpenSkill(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String, let s = store.skills.first(where: { $0.id == id }) { showDetail(s) }
    }
    @objc private func ctxCopySkill(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String, let s = store.skills.first(where: { $0.id == id }) { onCopy(s) }
    }
    @objc private func ctxRemoveSkill(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { folders.moveSkill(id, from: currentFolderId, to: folders.rootId) }
    }
    @objc private func ctxOpenFolder(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { navigate(to: id) }
    }
    @objc private func ctxRenameFolder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let node = folders.node(id) else { return }
        promptText("Rename folder", node.name) { [weak self] name in self?.folders.rename(id, to: name) }
    }
    @objc private func ctxDeleteFolder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let n = folders.node(id) else { return }
        let count = n.folders.count + n.skills.count
        if count > 0 {
            let a = NSAlert()
            a.messageText = "Delete “\(n.name)”?"
            a.informativeText = "Its \(count) item\(count == 1 ? "" : "s") move back to the parent. Your skills aren't uninstalled — this only changes how they're organized here."
            a.addButton(withTitle: "Delete Folder")
            a.addButton(withTitle: "Cancel")
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        folders.deleteFolder(id)
    }
    @objc private func ctxApply(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? CtxPayload else { return }
        if let sid = p.skillId {
            if p.copy { folders.copySkill(sid, to: p.target) }
            else { folders.moveSkill(sid, from: p.source ?? folders.rootId, to: p.target) }
        } else if let fid = p.folderId {
            folders.moveFolder(fid, to: p.target)
        }
    }

    // --- cut / copy / paste ---

    @objc private func ctxCutSkill(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let s = store.skills.first(where: { $0.id == id }) else { return }
        clip = Clip(id: id, isFolder: false, cut: true, source: currentFolderId, name: s.name)
        updatePasteButton()
    }
    @objc private func ctxCopySkillToClip(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let s = store.skills.first(where: { $0.id == id }) else { return }
        clip = Clip(id: id, isFolder: false, cut: false, source: currentFolderId, name: s.name)
        updatePasteButton()
    }
    @objc private func ctxCutFolder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let n = folders.node(id) else { return }
        clip = Clip(id: id, isFolder: true, cut: true, source: n.parent ?? folders.rootId, name: n.name)
        updatePasteButton()
    }
    @objc private func ctxNewSubfolder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        promptText("New folder name", "New Folder") { [weak self] name in self?.folders.createFolder(name: name, in: id) }
    }
    @objc private func pasteTapped() {
        guard let c = clip else { return }
        if c.isFolder {
            folders.moveFolder(c.id, to: currentFolderId)
            clip = nil
        } else if c.cut {
            folders.moveSkill(c.id, from: c.source, to: currentFolderId)
            clip = nil
        } else {
            folders.copySkill(c.id, to: currentFolderId)   // keep clipboard so you can paste into several folders
        }
        updatePasteButton()
    }
    private func updatePasteButton() {
        if let c = clip {
            pasteButton.isHidden = false
            pasteButton.title = "Paste \(c.name)"
            pasteButton.toolTip = c.cut ? "Move “\(c.name)” into this folder" : "Copy “\(c.name)” into this folder"
        } else {
            pasteButton.isHidden = true
        }
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
            let folderRows = folders.childFolders(of: currentId).map { folderRow($0) }
            if favs.isEmpty && folderRows.isEmpty {
                addEmpty("No favorites or folders yet.\nPin skills with ★ or create folders in the app —\nor search above to copy any skill.")
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
        let about = NSMenuItem(title: "About Skelf", action: #selector(aboutTapped), keyEquivalent: "")
        about.target = self; menu.addItem(about)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Skelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: optionsButton.bounds.height + 4), in: optionsButton)
    }

    @objc private func refreshTapped() { onRefresh?() }

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
    var viewController: SkillsViewController?
    var watcher: SkillWatcher?
    let popover = NSPopover()
    var popoverController: PopoverListController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.reload()
        folders.undoManager = undoManager
        folders.syncInstalled(Set(store.skills.map { $0.id }))
        setupMainMenu()
        dlog("launched -> \(store.skills.count) skills")
        // a pin OR a folder change anywhere re-renders both the window and the popover
        let refreshAll: () -> Void = { [weak self] in
            self?.viewController?.refreshFromStore()
            self?.popoverController?.reload()
        }
        favorites.onChange = refreshAll
        folders.onChange = refreshAll
        popover.delegate = self
        setupStatusItem()
        showWindow()
        startWatching()
        if let i = CommandLine.arguments.firstIndex(of: "--open"), i + 1 < CommandLine.arguments.count {
            viewController?.openDetail(id: CommandLine.arguments[i + 1])
        }
        if let i = CommandLine.arguments.firstIndex(of: "--enter"), i + 1 < CommandLine.arguments.count {
            viewController?.enterFolder(id: CommandLine.arguments[i + 1])
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
        popoverController?.reload()
        viewController?.refreshFromStore(auto: auto)
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
                self?.viewController?.openDetail(id: skill.id)
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
    }

    private func showWindow() {
        if window == nil {
            let vc = SkillsViewController(store: store, favorites: favorites, folders: folders, onCopy: { [weak self] skill in self?.copy(skill) })
            viewController = vc
            // Create with an explicit frame, THEN attach the content VC, so the window
            // keeps 760×580 instead of collapsing to the grid's (sizeless) fitting size.
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.contentViewController = vc
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
