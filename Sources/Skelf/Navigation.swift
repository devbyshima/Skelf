// SwiftUI navigation shell: routes, the observable model, Settings, screens, and AppKit representables.

import AppKit
import SwiftUI
import Observation
import QuartzCore
import CoreServices
import ServiceManagement
import Carbon.HIToolbox

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
    func folderName(_ id: String) -> String {
        id == favoritesFolderId ? "Favorites" : (folders.node(id)?.name ?? "Folder")
    }

    /// The folder currently on screen (the deepest `.folder` route), or root. Used by the
    /// File ▸ New Folder menu so a new folder lands where the user is looking.
    var currentFolderId: String {
        for route in path.reversed() { if case .folder(let id) = route { return id } }
        return folders.rootId
    }

    func openSkill(_ id: String) { if skill(id) != nil { path = [.skill(id)] } }
    func enterFolder(_ id: String) {
        if id == favoritesFolderId { path = [.folder(favoritesFolderId)]; return }
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
        if c.isFolder { folders.moveFolder(c.id, to: folderId); clip = nil } else if c.cut { folders.moveSkill(c.id, from: c.source, to: folderId); clip = nil } else { folders.copySkill(c.id, to: folderId) }   // keep clip for multi-paste
        Sound.play(.move)
    }
}

// The Settings window's categories — shown as the top toolbar tabs (icon + label).
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, intelligence, updates
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .intelligence: return "Intelligence"
        case .updates: return "Updates"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .intelligence: return "sparkles"
        case .updates: return "arrow.triangle.2.circlepath"
        }
    }
}

// One preferences pane — the controls shown under a single top toolbar tab.
struct SettingsPane: View {
    @Bindable var settings: AppSettings
    let tab: SettingsTab
    @State private var refreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            content
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 22)
        .frame(width: 470, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)   // natural height so the window fits each tab
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .general:
            check("Launch at Login", "Open Skelf automatically when you sign in.", $settings.launchAtLogin)
            check("Menu Bar Only", "Run Skelf from the menu bar without a Dock icon.", $settings.menuBarOnly)
            check("Global Shortcut", "Toggle the menu-bar popover from anywhere with \(GlobalHotKey.displayString).", $settings.globalHotKey)
            check("Play Sounds", "A subtle sound on copy and other actions.", $settings.playSounds)
        case .appearance:
            VStack(alignment: .leading, spacing: 6) {
                Text("Theme")
                Picker("", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
                caption("Match the system, or force a Light or Dark look.")
            }
            check("Show Art Covers", "Use NASA space imagery on skill cards. Off uses generated art (fully offline).", $settings.usePaintings)
            actionRow("Refresh Art", "Clear the downloaded art and fetch it again.",
                      button: refreshing ? "Refreshing…" : "Refresh", disabled: refreshing || !settings.usePaintings) {
                refreshing = true
                ArtStore.shared.clearCache()
                NotificationCenter.default.post(name: AppSettings.artChanged, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { refreshing = false }
            }
            check("Reduce Motion", "Turn off the pop and spring animations.", $settings.reduceMotion)
        case .intelligence:
            check("On-Device AI Search", "Find skills by what they do — type a task in plain words — and show plain-English summaries. Runs entirely on-device via Apple Intelligence; needs a supported Mac and falls back to plain search when unavailable.", $settings.useAIFeatures)
        case .updates:
            check("Automatically Check for Updates", "Look for a newer Skelf on launch and once a day.", $settings.autoCheckUpdates)
            actionRow("Check for Updates", "You’re on Skelf \(skelfShortVersion).", button: "Check Now", disabled: false) {
                NSApp.sendAction(#selector(AppDelegate.checkForUpdates), to: nil, from: nil)
            }
        }
    }

    // MARK: Native row builders

    /// A native checkbox + label, with a secondary description aligned under the label.
    @ViewBuilder private func check(_ title: String, _ subtitle: String, _ binding: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: binding) { Text(title) }
                .toggleStyle(.checkbox)
            caption(subtitle).padding(.leading, 19)   // align under the label, past the checkbox
        }
    }

    /// A label + description with a trailing native push button (Refresh, Check Now…).
    @ViewBuilder private func actionRow(_ title: String, _ subtitle: String, button: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                caption(subtitle)
            }
            Spacer(minLength: 8)
            Button(button, action: action).disabled(disabled)
        }
    }

    @ViewBuilder private func caption(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// The Settings window's content: a classic toolbar-tab preferences controller (icon + label tabs
// across the top, like Finder Settings). NSTabViewController installs the window toolbar and
// resizes the window to each pane; every tab hosts its SwiftUI SettingsPane.
final class SettingsTabController: NSTabViewController {
    init(settings: AppSettings) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let host = NSHostingController(rootView: SettingsPane(settings: settings, tab: tab))
            host.sizingOptions = .preferredContentSize   // size the window to each pane (resizes per tab)
            host.title = "Skelf Settings"                 // keep the window title steady across tabs
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.icon, accessibilityDescription: tab.title)
            addTabViewItem(item)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
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
        // The hosted AppKit grid can momentarily report a tiny fitting size during a
        // reload; without a floor the hosting controller shrinks the whole window to it.
        .frame(minWidth: 680, minHeight: 460)
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
            .searchable(text: $query, prompt: "Search all skills & folders")
            .toolbar {
                // The virtual Favorites folder can't hold sub-folders or pasted items.
                if folderId != favoritesFolderId {
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
                    // Split Settings into its own glass container — only meaningful when
                    // New Folder precedes it (so it's kept inside this conditional).
                    ToolbarSpacer(.fixed)
                }
                // Settings — its own button, available on every screen (stands alone on the
                // Favorites screen, where New Folder and the spacer above are absent).
                ToolbarItem {
                    Button { NSApp.sendAction(#selector(AppDelegate.openSettings), to: nil, from: nil) } label: {
                        Label("Settings", systemImage: "gearshape")
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
            .ignoresSafeArea(edges: .top)                    // banner fills under the transparent toolbar
            .navigationTitle("")
            .navigationBarBackButtonHidden(true)
            // The topbar is back, but transparent — its glass buttons are leveled with the traffic
            // lights and the banner art is the only background.
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { if !model.path.isEmpty { model.path.removeLast() } } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help("Back")
                }
                ToolbarItemGroup {
                    Button { if let s = model.skill(skillId) { model.copySkill(s) } } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy command")
                    Button { model.favorites.toggle(skillId) } label: {
                        Image(systemName: fav ? "star.fill" : "star")
                    }
                    .help(fav ? "Unfavorite" : "Favorite")
                }
            }
            .toolbarBackground(.hidden, for: .windowToolbar)  // transparent — the banner is the only background
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
        vc.apply(query: query, filter: filter, token: token, favToken: favToken)
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
        v.onBack = { if !model.path.isEmpty { model.path.removeLast() } }
        v.onCopy = { model.copySkill($0) }
        return v
    }
    func updateNSView(_ v: SkillDetailView, context: Context) {
        let c = context.coordinator
        // full reconfigure (re-renders the SKILL.md) only when the skill or data changes.
        if let s = model.skill(skillId), c.lastSkillId != skillId || c.lastToken != token {
            v.configure(s, isFavorite: model.favorites.isFavorite(skillId))
            c.lastSkillId = skillId; c.lastToken = token
        }
    }
}

// MARK: - Menu-bar popover (Passwords-style: Favorites + Folders containers)
