// Menu-bar popover, drop-in toast, painting panel, and small reusable controls.

import AppKit
import SwiftUI
import Observation
import QuartzCore
import CoreServices
import ServiceManagement
import Carbon.HIToolbox

final class ActionButton: NSButton {
    var onAction: (() -> Void)?
    @objc func fire() { onAction?() }
}

final class ClickableRow: NSView {
    var onClick: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var hovering = false

    override func mouseUp(with event: NSEvent) { onClick?() }

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
        layer?.cornerRadius = 0
        layer?.backgroundColor = hovering
            ? NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.7).cgColor
            : NSColor.clear.cgColor
    }
}

// The centered, Liquid-Glass painting-details panel: takes key focus so it closes on
// Escape and on click-away; fades + springs in on open and fades out on close.
final class PaintingPanel: NSPanel {
    private weak var scaleLayer: CALayer?
    private var closing = false
    override var canBecomeKey: Bool { true }

    func animateOpen(scaling layer: CALayer?) {
        scaleLayer = layer
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        springPop(layer, from: 0.92, damping: 14, stiffness: 240)
    }

    override func cancelOperation(_ sender: Any?) { close() }     // Escape
    override func resignKey() { super.resignKey(); close() }       // clicked outside

    override func close() {
        guard !closing else { return }
        closing = true
        if let l = scaleLayer {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15; ctx.allowsImplicitAnimation = true
                l.transform = centerScale(l, 0.96)
            }
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.finishClose() })
    }
    private func finishClose() { super.close() }
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
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor)
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
            undoBtn.centerYAnchor.constraint(equalTo: inner.centerYAnchor)
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
    var onSettings: (() -> Void)?
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
        backButton.contentTintColor = .secondaryLabelColor
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail

        windowButton.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Open Skelf window")
        windowButton.imagePosition = .imageOnly
        windowButton.isBordered = false
        windowButton.focusRingType = .none
        windowButton.contentTintColor = .secondaryLabelColor   // neutral chrome, not the accent
        windowButton.toolTip = "Open Skelf window"
        windowButton.target = self
        windowButton.action = #selector(openApp)
        windowButton.translatesAutoresizingMaskIntoConstraints = false
        windowButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)

        optionsButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Options")
        optionsButton.imagePosition = .imageOnly
        optionsButton.isBordered = false
        optionsButton.focusRingType = .none
        optionsButton.contentTintColor = .secondaryLabelColor
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
            contentStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -10)
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
            // Global search — SAME scope, fields, and ordering as the main app window
            // (every folder + every skill; matched on name/description/category/source;
            // enabled before off, name order), so search behaves identically in both.
            let foundFolders = folders.allFolders().filter { $0.name.lowercased().contains(q) }
            let matched = store.skills.filter {
                $0.name.lowercased().contains(q) || $0.category.lowercased().contains(q)
                    || $0.description.lowercased().contains(q) || $0.source.lowercased().contains(q)
            }
            let ordered = matched.filter { $0.enabled } + matched.filter { !$0.enabled }
            if ordered.isEmpty && foundFolders.isEmpty { addEmpty("Nothing matches.") } else {
                if !foundFolders.isEmpty { addSection("Folders", foundFolders.map { folderRow($0) }) }
                if !ordered.isEmpty { addSection("Skills", ordered.map { skillRow($0) }) }
            }
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
            if skills.isEmpty && subRows.isEmpty { addEmpty("This folder is empty.") } else {
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
            l.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -10)
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
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8)
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
        let row = makeRow(icon: skillThumb(skill), title: skill.name, subtitle: sub, dim: !skill.enabled,
                          trailing: copyBtn) { [weak self] in self?.onOpen?(skill) }
        return row
    }

    // The little square shows the skill's own painting (same as its grid card), with the
    // generated themed art as the instant fallback while the painting downloads.
    private func skillThumb(_ skill: Skill) -> NSView {
        let t = RowThumb()
        t.translatesAutoresizingMaskIntoConstraints = false
        t.widthAnchor.constraint(equalToConstant: 30).isActive = true
        t.heightAnchor.constraint(equalToConstant: 30).isActive = true
        if let img = ArtStore.shared.cached(skill.id) { t.setImage(img) } else {
            t.setCG(SkillArtView.themedImage(skill))
            ArtStore.shared.fetch(skill) { [weak t] img in
                guard let t = t, let img = img else { return }; t.setImage(img)
            }
        }
        t.alphaValue = skill.enabled ? 1.0 : 0.5
        return t
    }

    // Creator folders show the creator's GitHub avatar; user folders keep the folder glyph.
    private func folderThumb(_ node: FolderStore.Node) -> NSView {
        guard let creator = node.autoCreator else { return folderIcon() }
        let t = RowThumb()
        t.translatesAutoresizingMaskIntoConstraints = false
        t.widthAnchor.constraint(equalToConstant: 30).isActive = true
        t.heightAnchor.constraint(equalToConstant: 30).isActive = true
        if let img = AvatarStore.shared.cached(creator) { t.setImage(img) } else {
            t.setCG(SkillArtView.gradientImage(node.name, monogram: true))
            AvatarStore.shared.fetch(creator) { [weak t] img in
                guard let t = t, let img = img else { return }; t.setImage(img)
            }
        }
        return t
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
        let row = makeRow(icon: folderThumb(node), title: node.name, subtitle: parts.joined(separator: " · "),
                          dim: false, trailing: chev) { [weak self] in self?.enter(node.id) }
        return row
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
    private func enter(_ id: String) {
        // Entering a folder from search results leaves search behind, so reload() shows the
        // folder's contents (not the global results) and the field clears.
        if !query.isEmpty { query = ""; searchField.stringValue = "" }
        currentId = id; reload(); slideContent(from: 38)
    }

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
        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsTapped), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
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
    @objc private func settingsTapped() { onSettings?() }

    @objc private func toggleSounds() { Sound.setEnabled(!Sound.enabled); AppSettings.shared.playSounds = Sound.enabled }

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
