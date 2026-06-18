// A minimal Liquid Glass hover tip for skill cards — it replaces the cramped yellow system
// tooltip with a small glass card showing only the relevant essentials (name, the slash
// command you'd copy, and the creator). One shared, reused panel: it fades in after a short
// rest on a card and out on exit, with corners that match the app's other glass surfaces.

import AppKit

final class SkillHoverTip {
    static let shared = SkillHoverTip()

    private let panel: NSPanel
    private let glass = NSGlassEffectView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let cmdLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var pending: DispatchWorkItem?
    private var shownFor: String?

    private let maxWidth: CGFloat = 268
    private let padX: CGFloat = 14, padY: CGFloat = 11

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 72),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true                 // a tip, never a hover target
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let container = NSView(); container.wantsLayer = true
        panel.contentView = container

        glass.cornerRadius = 14                          // matches the toast / popover glass
        glass.style = .regular
        glass.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        for l in [nameLabel, cmdLabel, metaLabel] { l.lineBreakMode = .byTruncatingTail; l.maximumNumberOfLines = 1 }
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        cmdLabel.font = skelfMono(.callout, .medium)
        cmdLabel.textColor = .controlAccentColor
        metaLabel.font = .systemFont(ofSize: 11, weight: .regular)
        metaLabel.textColor = .secondaryLabelColor

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(nameLabel)
        stack.addArrangedSubview(cmdLabel)
        stack.addArrangedSubview(metaLabel)

        let inner = NSView()
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: padX),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: inner.trailingAnchor, constant: -padX),
            stack.topAnchor.constraint(equalTo: inner.topAnchor, constant: padY),
            stack.bottomAnchor.constraint(equalTo: inner.bottomAnchor, constant: -padY),
        ])
        glass.contentView = inner
    }

    /// Show the tip for a card after a brief rest (so flicking across cards doesn't flash it).
    func schedule(for skill: Skill, cardScreenFrame: NSRect, on screen: NSScreen?) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.present(skill, cardScreenFrame, screen) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Cancel a pending tip and fade out any visible one.
    func cancel() {
        pending?.cancel(); pending = nil
        shownFor = nil
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            if self.panel.alphaValue == 0 { self.panel.orderOut(nil) }
        })
    }

    private func present(_ skill: Skill, _ card: NSRect, _ screen: NSScreen?) {
        nameLabel.stringValue = skill.name
        cmdLabel.stringValue = skill.initiator
        let creator = FolderStore.creatorName(skill.source)
        var meta = (creator.isEmpty || creator == "Local") ? "" : "by \(creator)"
        if !skill.enabled { meta += meta.isEmpty ? "Disabled" : "  ·  off" }
        metaLabel.stringValue = meta
        metaLabel.isHidden = meta.isEmpty

        // Size to content (single-line labels → width is the widest label, capped).
        let textW = ceil(max(nameLabel.intrinsicContentSize.width,
                             cmdLabel.intrinsicContentSize.width,
                             metaLabel.isHidden ? 0 : metaLabel.intrinsicContentSize.width))
        let w = min(textW + padX * 2, maxWidth)
        panel.setContentSize(NSSize(width: w, height: 200))
        panel.contentView?.layoutSubtreeIfNeeded()
        let h = ceil(stack.fittingSize.height) + padY * 2
        panel.setContentSize(NSSize(width: w, height: h))

        // Position centered just below the card, flipping above if there's no room.
        let vf = (screen ?? NSScreen.main)?.visibleFrame ?? card
        var x = card.midX - w / 2
        var y = card.minY - 8 - h
        if y < vf.minY + 6 { y = card.maxY + 8 }
        x = max(vf.minX + 6, min(x, vf.maxX - w - 6))
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))

        if shownFor == skill.id, panel.isVisible {
            panel.alphaValue = 1
        } else {
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        shownFor = skill.id
    }
}
