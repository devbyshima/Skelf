// The collection view, adaptive flow layout, section header, and grid view controller.

import AppKit
import SwiftUI
import Observation
import QuartzCore
import CoreServices
import ServiceManagement
import Carbon.HIToolbox

final class GridCollectionView: NSCollectionView {
    var onActivate: ((IndexPath) -> Void)?
    private var downIP: IndexPath?

    // A single click on a tile opens it. (Drag-and-drop / reorder were removed, so
    // there's no gesture tracking — just press-then-release on the same item.)
    override func mouseDown(with event: NSEvent) {
        downIP = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        let ip = downIP
        super.mouseUp(with: event)
        let upIP = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        if let ip = ip, ip == upIP, event.clickCount == 1 { onActivate?(ip) }
        downIP = nil
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
    let headerHeight: CGFloat = 38

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
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
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
    private var lastFavToken = -1
    func apply(query: String, filter: Int, token: Int, favToken: Int) {
        let favChanged = favToken != lastFavToken
        // A favorite toggle must REBUILD when the favorites set is what's on screen — the
        // home grid (its Favorites count card) or the Favorites folder itself — but only
        // needs a light in-place star refresh inside ordinary folders.
        let favNeedsRebuild = favChanged && (folderId == favoritesFolderId || folderId == model.folders.rootId)
        let rebuild = query != self.query || token != lastToken || favNeedsRebuild
        self.query = query; lastToken = token; lastFavToken = favToken
        guard isViewLoaded else { return }
        if rebuild { reload() }
        else if favChanged { refreshFavorites() }
    }

    // Clear any hover tip first: reloadData() tears down items without firing mouseExited,
    // so a tip for a card that's about to vanish could otherwise stay stuck on screen.
    func reload() { SkillHoverTip.shared.cancel(); buildEntries(); collectionView.reloadData() }

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

    private func buildEntries() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()

        // GLOBAL SEARCH — any non-empty query searches the WHOLE library (every folder and
        // every skill across the tree), no matter which screen it was typed on, so it always
        // gets you to what you're looking for. Folders open; skills open their detail. This
        // wins over the per-folder / Favorites scoping below.
        if !q.isEmpty {
            let foundFolders = model.folders.allFolders().filter { $0.name.lowercased().contains(q) }
            let matched = model.store.skills.filter { skillMatches($0, q) }
            let on = matched.filter { $0.enabled }, off = matched.filter { !$0.enabled }
            var s: [(title: String, items: [GridEntry])] = []
            if !foundFolders.isEmpty { s.append(("Folders", foundFolders.map { .folder($0) })) }
            if !on.isEmpty { s.append(("Skills", on.map { .skill($0) })) }
            if !off.isEmpty { s.append(("Off Skills", off.map { .skill($0) })) }
            sections = s
            return
        }

        // The virtual Favorites folder: every favorited skill, wherever it lives.
        if folderId == favoritesFolderId {
            let favs = model.store.skills.filter { model.favorites.isFavorite($0.id) && skillMatches($0, q) }
            var s: [(title: String, items: [GridEntry])] = []
            let on = favs.filter { $0.enabled }, off = favs.filter { !$0.enabled }
            if !on.isEmpty { s.append(("Skills", on.map { .skill($0) })) }
            if !off.isEmpty { s.append(("Off Skills", off.map { .skill($0) })) }
            sections = s
            return
        }

        let folders = model.folders.childFolders(of: folderId).filter { q.isEmpty || $0.name.lowercased().contains(q) }
        let here = model.folders.skillIds(in: folderId).compactMap { id in model.store.skills.first { $0.id == id } }
        let skills = here.filter { $0.enabled && skillMatches($0, q) }     // stored order; favoriting never reorders
        let off = here.filter { !$0.enabled && skillMatches($0, q) }
        var folderEntries: [GridEntry] = folders.map { .folder($0) }
        // Pin the special Favorites folder first on the home grid (not while searching).
        if folderId == model.folders.rootId && q.isEmpty {
            let favCount = model.store.skills.filter { model.favorites.isFavorite($0.id) }.count
            folderEntries.insert(.favorites(favCount), at: 0)
        }
        var s: [(title: String, items: [GridEntry])] = []
        if !folderEntries.isEmpty { s.append(("Folders", folderEntries)) }
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
        case .favorites: (collectionView.item(at: ip) as? FolderGridItem)?.pressPop(); onOpenFolder?(favoritesFolderId)
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
        case .favorites(let count):
            let item = cv.makeItem(withIdentifier: folderItemID, for: indexPath)
            (item as? FolderGridItem)?.configureFavorites(count: count)
            item.view.menu = nil
            return item
        case .folder(let node):
            let item = cv.makeItem(withIdentifier: folderItemID, for: indexPath)
            if let folder = item as? FolderGridItem {
                // custom folders get a mosaic of their (up to 4) skills' art
                let mosaicSkills = node.autoCreator == nil
                    ? node.skills.prefix(4).compactMap { id in model.store.skills.first { $0.id == id } }
                    : []
                folder.configure(node, inMenuBar: model.folders.showsInMenuBar(node.id), mosaicSkills: mosaicSkills)
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
        case .none:
            return cv.makeItem(withIdentifier: skillItemID, for: indexPath)
        }
    }

    private func popMenu(_ menu: NSMenu, at anchor: NSView) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 2), in: anchor)
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

