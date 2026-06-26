// NSWindow centering helper, the AppDelegate (status item, menus, lifecycle), and the @main entry.

import AppKit
import SwiftUI
import Observation
import QuartzCore
import CoreServices
import ServiceManagement
import Carbon.HIToolbox

extension NSWindow {
    /// Position truly centered on a screen — both axes, not NSWindow.center()'s
    /// above-center bias. Falls back to the window's own screen, then the main screen.
    func centerInScreen(_ screen: NSScreen? = nil) {
        guard let vf = (screen ?? self.screen ?? NSScreen.main)?.visibleFrame else { center(); return }
        let f = frame
        // Center, but clamp the origin so an oversized window keeps its top-left on-screen
        // (controls stay reachable) rather than hanging off both edges.
        let x = max(vf.minX, min(vf.minX + (vf.width - f.width) / 2, vf.maxX - f.width))
        let y = max(vf.minY, min(vf.minY + (vf.height - f.height) / 2, vf.maxY - f.height))
        setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    let store = SkillStore()
    let favorites = Favorites()
    let folders = FolderStore()
    let undoManager = UndoManager()
    var statusItem: NSStatusItem!
    var window: NSWindow?
    var settingsWindow: NSWindow?
    var model: SkelfModel?
    var watcher: SkillWatcher?
    var updateTimer: Timer?
    let popover = NSPopover()
    var popoverController: PopoverListController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Was Skelf auto-started at login (a registered login item) rather than opened by the
        // user? Read it now, before our own Apple events fire. Used below to keep a login launch
        // quiet — just the menu-bar icon — when Menu-Bar-Only is on.
        let launchedAtLogin = Self.launchedAsLoginItem()
        AppSettings.shared.applyOnLaunch()    // restore Menu-Bar-Only (Dock icon) before the UI shows
        store.reload()
        ArtStore.shared.updateAssignment(store.skills.map { $0.id })   // assign a distinct NASA image per skill
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
        // Toggling "Show Painting Covers" re-renders the grid + popover with the new art.
        NotificationCenter.default.addObserver(forName: AppSettings.artChanged, object: nil, queue: .main) { [weak self] _ in
            self?.model?.bumpReload(); self?.popoverController?.reload()
        }
        popover.delegate = self
        setupStatusItem()
        // The system-wide ⌥⌘S hot-key toggles the popover (registers only if the user left it on).
        GlobalHotKey.shared.onFire = { [weak self] in self?.togglePopover(nil) }
        AppSettings.shared.applyHotKey()
        // A login launch in Menu-Bar-Only mode stays as just the menu-bar icon — no window. Any
        // other launch (manual open, or not Menu-Bar-Only) opens the window as before.
        dlog("launch: loginItem=\(launchedAtLogin) menuBarOnly=\(AppSettings.shared.menuBarOnly)")
        if !(launchedAtLogin && AppSettings.shared.menuBarOnly) { showWindow() }
        startWatching()
        // Auto-update: a quick check shortly after launch, then periodically (each call
        // self-throttles to ~once a day and honors the Settings toggle).
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { Updater.checkInBackgroundIfDue() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Updater.checkInBackgroundIfDue()
        }
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

    /// True when macOS auto-launched Skelf at login (as a registered login item) rather than the
    /// user opening it — read from the Open-Application Apple event's login-item flag. (The
    /// FourCharCodes 'aevt'/'oapp'/'prdt'/'lgit' aren't all surfaced to Swift, so they're spelled out.)
    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication) else {
            return false
        }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?
            .enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    /// ⌘Q / "Quit Skelf". In Menu-Bar-Only mode this tucks Skelf back into the menu bar (the
    /// status item keeps running); in the regular windowed mode it quits completely, like any
    /// app. "Quit Completely" always exits, in either mode.
    @objc private func quitToMenuBar() {
        guard AppSettings.shared.menuBarOnly else { NSApp.terminate(nil); return }
        settingsWindow?.orderOut(nil)
        window?.close()                 // isReleasedWhenClosed = false, so this just hides it
        NSApp.hide(nil)                 // yield focus back to the previous app
    }

    /// Fully terminate Skelf, removing the menu-bar icon. Wired to "Quit Completely".
    @objc func quitCompletely() { NSApp.terminate(nil) }

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
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Skelf", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        // ⌘Q quits completely in the regular windowed mode; in Menu-Bar-Only mode it tucks Skelf
        // into the menu bar. "Quit Completely" (⌥⌘Q, also in the menu-bar ⋯ menu) always exits.
        appMenu.addItem(withTitle: "Quit Skelf", action: #selector(quitToMenuBar), keyEquivalent: "q").target = self
        let quitAll = appMenu.addItem(withTitle: "Quit Completely", action: #selector(quitCompletely), keyEquivalent: "q")
        quitAll.keyEquivalentModifierMask = [.command, .option]
        quitAll.target = self

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "New Folder", action: #selector(newFolderAction), keyEquivalent: "n").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Refresh Skills", action: #selector(refreshSkills), keyEquivalent: "r").target = self
        let closeWin = fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeWin.keyEquivalentModifierMask = [.command]

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

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu      // lets macOS list/track open windows here

        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        helpMenu.addItem(withTitle: "Skelf Help", action: #selector(showHelp), keyEquivalent: "?").target = self
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
    }

    @objc private func showAbout() {
        let a = NSAlert()
        a.messageText = "Skelf"
        a.informativeText = "A menu-bar browser for your installed Claude Code skills.\n\n\(store.skills.count) skills installed.\n\nCard art is public-domain imagery courtesy of NASA (images.nasa.gov). Skelf isn’t affiliated with or endorsed by NASA."
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    @objc func checkForUpdates() { Updater.checkManually() }

    @objc func openSettings() {
        if settingsWindow == nil {
            // Classic toolbar-tab preferences (icon + label tabs up top, like Finder Settings).
            // NSTabViewController installs the window toolbar and resizes the window per tab.
            let tc = SettingsTabController(settings: AppSettings.shared)
            let w = NSWindow(contentViewController: tc)
            w.title = "Skelf Settings"
            w.styleMask = [.titled, .closable]            // non-resizable preferences window
            w.toolbarStyle = .preference                  // centered icon+label tabs
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        // True-center on the screen showing the main window when it (re)opens — but don't
        // yank a Settings window that's already open (the user may have moved it).
        if settingsWindow?.isVisible != true { settingsWindow?.centerInScreen(window?.screen) }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // File ▸ New Folder — create a folder where the user is currently looking.
    @objc private func newFolderAction() {
        showWindow()
        model?.newFolder(in: model?.currentFolderId ?? folders.rootId)
    }

    // File ▸ Refresh Skills (⌘R) — re-scan the skill directories now.
    @objc private func refreshSkills() { reloadFromDisk(auto: false) }

    // Help ▸ Skelf Help — a short primer (no bundled help book).
    @objc private func showHelp() {
        let a = NSAlert()
        a.messageText = "Skelf Help"
        a.informativeText = """
        Browse your installed Claude Code skills as a grid of painting-covered cards.

        • Click a card to open its details, then Copy to put its /slash-command on the clipboard.
        • Click a card's ★ to favorite it — favorites pin to the top and to the menu bar.
        • Folders group skills by creator automatically; make your own with File ▸ New Folder.
        • Press \(GlobalHotKey.displayString) anywhere to open the menu-bar popover.
        • Tune behavior in Settings (⌘,) — Launch at Login, Menu Bar Only, theme, and more.
        """
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    private func startWatching() {
        watcher = SkillWatcher(paths: SkillStore.watchPaths()) { [weak self] in
            self?.reloadFromDisk(auto: true)
        }
        watcher?.start()
    }

    private func reloadFromDisk(auto: Bool) {
        if !auto { SkillStore.invalidateRootCache() }   // a manual Refresh re-scans for new roots
        store.reload()
        ArtStore.shared.updateAssignment(store.skills.map { $0.id })
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
        if ProcessInfo.processInfo.environment["SKELF_DEBUG"] != nil {
            FileHandle.standardError.write(("[skelf] " + s + "\n").data(using: .utf8)!)
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

    /// The Skelf mark as a menu-bar template image (vector PDF), falling back to an SF symbol.
    ///
    /// The icon ships as a PDF (`skelf-menubar.pdf`, generated from skelf.svg) and is loaded as a
    /// template — the canonical, toolchain-robust way to do a menu-bar icon. Earlier releases
    /// instead rasterized the SVG into a hand-built `NSBitmapImageRep` template at runtime; that
    /// draws fine offscreen but renders BLANK in the live status bar when the app is built against
    /// the macOS 26 SDK (the shipped release had an invisible icon). A PDF goes through AppKit's
    /// own vector-template path — the same one asset-catalog template images use — and renders.
    private func menuBarIcon() -> NSImage {
        let size = NSSize(width: 22, height: 16)               // mark is ~1.38:1, sized for the bar
        if let p = skelfResourceBundle.path(forResource: "skelf-menubar", ofType: "pdf"),
           let pdf = NSImage(contentsOfFile: p) {
            pdf.size = size
            pdf.isTemplate = true                              // tints to the menu-bar colour, adapts light/dark
            return pdf
        }
        let fallback = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Skelf")
            ?? NSImage(size: size)
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
            ctrl.onSettings = { [weak self] in self?.popover.performClose(nil); self?.openSettings() }
            ctrl.onQuit = { [weak self] in self?.quitCompletely() }
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
            let defaultSize = NSSize(width: 1200, height: 716)   // first-launch default; tuned so the
                                                                  // SKILL.md card and the sidebar line up
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: defaultSize),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.contentViewController = host
            w.title = "Skelf"
            // The skill page owns its whole header: let content draw under the title bar so the
            // traffic lights float over the banner art, and never show the window title text.
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.minSize = NSSize(width: 680, height: 460)
            w.contentMinSize = NSSize(width: 680, height: 460)   // also floor the content size
            w.setContentSize(defaultSize)
            w.center()
            // Remember the user's resizes across launches; first launch uses defaultSize above.
            w.setFrameAutosaveName("SkelfMainWindow")
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
struct SkelfMain {
    static func main() {
        if CommandLine.arguments.contains("--version") || CommandLine.arguments.contains("-v") {
            print("Skelf \(skelfShortVersion) (build \(skelfBuildVersion))")
            exit(0)
        }
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
        if let idx = CommandLine.arguments.firstIndex(of: "--copy") {
            guard idx + 1 < CommandLine.arguments.count else {
                FileHandle.standardError.write(Data("usage: Skelf --copy <skill-id>\n".utf8))
                exit(1)
            }
            let id = CommandLine.arguments[idx + 1]
            let store = SkillStore()
            store.reload()
            guard let skill = store.skills.first(where: { $0.id == id }) else {
                FileHandle.standardError.write(Data("no such skill: \(id)\n".utf8))
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
