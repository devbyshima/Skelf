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
    let popover = NSPopover()
    var popoverController: PopoverListController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.shared.applyOnLaunch()    // restore Menu-Bar-Only (Dock icon) before the UI shows
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
        // Toggling "Show Painting Covers" re-renders the grid + popover with the new art.
        NotificationCenter.default.addObserver(forName: AppSettings.artChanged, object: nil, queue: .main) { [weak self] _ in
            self?.model?.bumpReload(); self?.popoverController?.reload()
        }
        popover.delegate = self
        setupStatusItem()
        // The system-wide ⌥⌘S hot-key toggles the popover (registers only if the user left it on).
        GlobalHotKey.shared.onFire = { [weak self] in self?.togglePopover(nil) }
        AppSettings.shared.applyHotKey()
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
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Skelf", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Skelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

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
        a.informativeText = "A menu-bar browser for your installed Claude Code skills.\n\n\(store.skills.count) skills installed."
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(settings: AppSettings.shared))
            host.view.layoutSubtreeIfNeeded()             // resolve the SwiftUI size now…
            let w = NSWindow(contentViewController: host)
            w.title = "Skelf Settings"
            w.styleMask = [.titled, .closable]            // standard, non-resizable Settings window
            w.isReleasedWhenClosed = false
            w.setContentSize(host.view.fittingSize)       // …so centering uses the real frame, not a stale one
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

    /// The Skelf mark (from skelf.svg) as a menu-bar template image, falling back to an SF symbol.
    ///
    /// The SVG must be RASTERIZED into a concrete bitmap first. `NSImage(contentsOfFile:)` on an
    /// SVG yields a vector-only representation (`_NSSVGImageRep`, 0×0 pixels) that draws fine in
    /// an offscreen context but renders BLANK in the live status bar — which is why the menu-bar
    /// icon never appeared in the release. Drawing it into bitmap reps (@1x + @2x) gives the
    /// status button real pixels to composite as a template.
    private func menuBarIcon() -> NSImage {
        let size = NSSize(width: 22, height: 16)               // svg mark is ~1.38:1, sized for the bar
        if let p = skelfResourceBundle.path(forResource: "skelf", ofType: "svg"),
           let svg = NSImage(contentsOfFile: p),
           let icon = rasterizedTemplate(svg, size: size) {
            return icon
        }
        let fallback = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Skelf")
            ?? NSImage(size: size)
        fallback.isTemplate = true
        return fallback
    }

    /// Draw `source` into bitmap reps at @1x and @2x and return a template image whose alpha the
    /// menu bar tints to the bar colour. Returns nil if every pixel came out transparent, so the
    /// caller can fall back to the SF symbol rather than show an invisible icon.
    private func rasterizedTemplate(_ source: NSImage, size: NSSize) -> NSImage? {
        let image = NSImage(size: size)
        var anyOpaque = false
        for scale in [1, 2] {
            let pw = Int(size.width.rounded()) * scale, ph = Int(size.height.rounded()) * scale
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            source.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
            if !anyOpaque {
                let step = max(1, pw / 16)
                for y in stride(from: 0, to: ph, by: step) where !anyOpaque {
                    for x in stride(from: 0, to: pw, by: step) {
                        if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.01 { anyOpaque = true; break }
                    }
                }
            }
        }
        guard anyOpaque else { return nil }
        image.isTemplate = true                                // tints to the menu-bar colour, adapts light/dark
        return image
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
            let defaultSize = NSSize(width: 1200, height: 716)   // first-launch default; tuned so the
                                                                  // SKILL.md card and the sidebar line up
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: defaultSize),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.contentViewController = host
            w.title = "Skelf"
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
