// The two-column skill detail view (banner + SKILL.md + sticky sidebar) and menu helpers.

import AppKit
import SwiftUI
import Observation
import QuartzCore
import CoreServices
import ServiceManagement
import Carbon.HIToolbox

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
    private let bodyText = NSTextView()   // SKILL.md body — scrolls internally for big files
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
        banner.toolTip = "Click for details about this painting"
        banner.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(bannerClicked)))
        bannerName.font = .systemFont(ofSize: 28, weight: .bold)   // the page title — clearly largest
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

        // left: a fixed Summary header above the SKILL.md, which lives in its OWN scrolling
        // NSTextView — viewport layout keeps a big SKILL.md (e.g. humanizer's 34KB) fast to
        // open and smooth to scroll (a single giant NSTextField laid the whole thing out up
        // front, which was the open-lag and scroll-jank).
        let leftBox = NSView()
        leftBox.translatesAutoresizingMaskIntoConstraints = false
        bodyRow.addSubview(leftBox)

        // Summary block (the description), pinned at the top.
        let summaryHeader = NSTextField(labelWithString: "SUMMARY")
        summaryHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        summaryHeader.textColor = .secondaryLabelColor
        summaryHeader.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = .systemFont(ofSize: 14.5)
        summaryLabel.textColor = .labelColor
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        let summaryBlock = NSStackView(views: [summaryHeader, summaryLabel])
        summaryBlock.orientation = .vertical; summaryBlock.alignment = .leading; summaryBlock.spacing = 6
        summaryBlock.translatesAutoresizingMaskIntoConstraints = false
        leftBox.addSubview(summaryBlock)

        // GitHub-style README card: bordered, file-header bar, then the body in a scroll view.
        let readmeCard = NSView()
        readmeCard.wantsLayer = true
        readmeCard.layer?.cornerRadius = 8
        readmeCard.layer?.borderWidth = 1
        readmeCard.layer?.borderColor = NSColor.separatorColor.cgColor
        readmeCard.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        readmeCard.layer?.masksToBounds = true
        readmeCard.translatesAutoresizingMaskIntoConstraints = false
        leftBox.addSubview(readmeCard)
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

        // the rendered SKILL.md, in its own scroll view (NSTextView document = lazy layout)
        let bodyScroll = NSScrollView()
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.scrollerStyle = .overlay
        bodyScroll.drawsBackground = false
        bodyScroll.borderType = .noBorder
        readmeCard.addSubview(bodyScroll)
        bodyText.isEditable = false
        bodyText.isSelectable = true
        bodyText.drawsBackground = false
        bodyText.textContainerInset = NSSize(width: 18, height: 16)
        bodyText.minSize = NSSize(width: 0, height: 0)
        bodyText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        bodyText.isVerticallyResizable = true
        bodyText.isHorizontallyResizable = false
        bodyText.autoresizingMask = [.width]
        bodyText.textContainer?.widthTracksTextView = true
        bodyText.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        bodyText.layoutManager?.allowsNonContiguousLayout = true
        bodyText.linkTextAttributes = [.foregroundColor: NSColor.linkColor,
                                       .underlineStyle: NSUnderlineStyle.single.rawValue]
        bodyScroll.documentView = bodyText

        NSLayoutConstraint.activate([
            summaryBlock.topAnchor.constraint(equalTo: leftBox.topAnchor, constant: 20),
            summaryBlock.leadingAnchor.constraint(equalTo: leftBox.leadingAnchor, constant: 24),
            summaryBlock.trailingAnchor.constraint(equalTo: leftBox.trailingAnchor, constant: -22),

            readmeCard.topAnchor.constraint(equalTo: summaryBlock.bottomAnchor, constant: 16),
            readmeCard.leadingAnchor.constraint(equalTo: leftBox.leadingAnchor, constant: 24),
            readmeCard.trailingAnchor.constraint(equalTo: leftBox.trailingAnchor, constant: -22),
            readmeCard.bottomAnchor.constraint(equalTo: leftBox.bottomAnchor, constant: -20),   // fills + resizes with the window

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

            bodyScroll.topAnchor.constraint(equalTo: hdrDivider.bottomAnchor),
            bodyScroll.leadingAnchor.constraint(equalTo: readmeCard.leadingAnchor),
            bodyScroll.trailingAnchor.constraint(equalTo: readmeCard.trailingAnchor),
            bodyScroll.bottomAnchor.constraint(equalTo: readmeCard.bottomAnchor),
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

            leftBox.topAnchor.constraint(equalTo: bodyRow.topAnchor),
            leftBox.leadingAnchor.constraint(equalTo: bodyRow.leadingAnchor),
            leftBox.bottomAnchor.constraint(equalTo: bodyRow.bottomAnchor),
            leftBox.trailingAnchor.constraint(equalTo: sidebarScroll.leadingAnchor),

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
        // The header banner wears the skill's own art (same as its card); the Source
        // sidebar below keeps the creator avatar.
        if let img = ArtStore.shared.cached(skill.id) { banner.setAvatar(img) }
        else {
            banner.setThemedFallback(skill)
            ArtStore.shared.fetch(skill) { [weak self] img in
                guard let self = self, self.artToken == token, let img = img else { return }
                self.banner.setAvatar(img)
            }
        }
        bannerName.stringValue = skill.name
        bannerPillLabel.stringValue = skill.initiator
        bannerStatus.stringValue = skill.enabled ? "● Enabled" : "○ Installed · off"
        bannerStatus.textColor = skill.enabled ? NSColor.systemGreen : NSColor.white.withAlphaComponent(0.8)

        // left column: Summary + the GitHub-style SKILL.md card. The body NSTextView lays out
        // lazily (viewport), so a cached render shows instantly; otherwise read+render OFF the
        // main thread (the navigation push stays smooth) and swap it in, caching for re-opens.
        summaryLabel.stringValue = skill.description.isEmpty ? "No description in SKILL.md." : skill.description
        let sid = skill.id
        if let cached = Self.mdCache[sid] {
            setBody(cached)
        } else {
            setBody(NSAttributedString(string: "Loading…",
                attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor]))
            let mdPath = skill.skillMDPath
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let raw = (try? String(contentsOfFile: mdPath, encoding: .utf8)) ?? ""
                let (_, body) = splitFrontmatter(raw)
                let bodyTrim = body.trimmingCharacters(in: .whitespacesAndNewlines)
                let attr = bodyTrim.isEmpty
                    ? NSAttributedString(string: "This skill's SKILL.md has no content beyond its frontmatter.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
                    : renderGitHubMarkdown(bodyTrim)
                DispatchQueue.main.async {
                    Self.mdCache[sid] = attr
                    guard let self = self, self.skill?.id == sid else { return }   // still this skill
                    self.setBody(attr)
                }
            }
        }

        rebuildSidebar(skill, isFavorite: isFavorite, creator: creator, token: token)
    }

    private static var mdCache: [String: NSAttributedString] = [:]
    private func setBody(_ attr: NSAttributedString) {
        bodyText.textStorage?.setAttributedString(attr)
        bodyText.scroll(NSPoint(x: 0, y: 0))   // reset scroll to top for the new skill
    }

    // Clicking the banner painting → a floating Liquid-Glass panel CENTERED on screen. The
    // layout ADAPTS to the artwork: a landscape painting sits full-bleed on top with the info
    // below; a portrait painting sits on the LEFT (shown whole, never cropped) with the info
    // on the RIGHT.
    private var paintingPanel: NSPanel?
    @objc private func bannerClicked() {
        guard let skill = skill else { return }
        let img = ArtStore.shared.cached(skill.id)
        let aspect: CGFloat = (img.map { $0.size.width > 0 ? $0.size.height / $0.size.width : 1.31 }) ?? 420.0 / 320.0
        let portrait = aspect > 1.12
        let screenMaxH = ((self.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900) - 100
        let radius: CGFloat = 20

        let art = SkillArtView(); art.showScrim = false
        art.translatesAutoresizingMaskIntoConstraints = false
        if let img = img { art.setAvatar(img) } else { art.setThemedFallback(skill) }

        let infoColW: CGFloat = portrait ? 480 : 760
        let info = paintingInfo(skill, columnWidth: infoColW)
        info.translatesAutoresizingMaskIntoConstraints = false
        info.layoutSubtreeIfNeeded()
        let infoH = ceil(info.fittingSize.height)

        let card = NSView(); card.wantsLayer = true
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(art); card.addSubview(info)

        var W: CGFloat, H: CGFloat
        if portrait {
            // image LEFT, fills the panel height at the painting's exact aspect (no crop); info RIGHT
            H = max(infoH, 560)
            let imageW = (H / aspect).rounded()
            W = imageW + infoColW
            NSLayoutConstraint.activate([
                art.topAnchor.constraint(equalTo: card.topAnchor),
                art.bottomAnchor.constraint(equalTo: card.bottomAnchor),
                art.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                art.widthAnchor.constraint(equalToConstant: imageW),
                info.topAnchor.constraint(equalTo: card.topAnchor),
                info.leadingAnchor.constraint(equalTo: art.trailingAnchor),
                info.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                info.widthAnchor.constraint(equalToConstant: infoColW),
                card.widthAnchor.constraint(equalToConstant: W),
                card.heightAnchor.constraint(equalToConstant: H),
            ])
        } else {
            // image TOP full-bleed, info BELOW
            W = 760
            let imgH = min(W * aspect, 440)
            H = imgH + infoH
            NSLayoutConstraint.activate([
                art.topAnchor.constraint(equalTo: card.topAnchor),
                art.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                art.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                art.heightAnchor.constraint(equalToConstant: imgH),
                info.topAnchor.constraint(equalTo: art.bottomAnchor),
                info.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                info.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                card.widthAnchor.constraint(equalToConstant: W),
                card.heightAnchor.constraint(equalToConstant: H),
            ])
        }

        let panelH = min(H, screenMaxH)
        let content: NSView
        if H > screenMaxH {                            // taller than the screen → scroll the whole card
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: W, height: panelH))
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.drawsBackground = false; scroll.borderType = .noBorder
            scroll.documentView = card
            content = scroll
        } else {
            content = card
        }

        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: W, height: panelH))
        glass.cornerRadius = radius
        glass.autoresizingMask = [.width, .height]
        glass.contentView = content
        content.wantsLayer = true
        content.layer?.cornerRadius = radius
        content.layer?.masksToBounds = true

        // Borderless (no traffic-light close button); closes on Escape / click-away.
        let panel = PaintingPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: panelH),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentView = glass
        panel.centerInScreen(self.window?.screen)
        panel.level = .floating
        panel.makeKeyAndOrderFront(nil)
        panel.animateOpen(scaling: glass.layer)
        paintingPanel = panel
    }

    // The info column shown beside/under the painting: title, artist, facts, the museum
    // description, and a highlighted "why this painting" callout. Padded; intrinsic height.
    private func paintingInfo(_ skill: Skill, columnWidth colW: CGFloat) -> NSView {
        let d = ArtStore.shared.details(skill.id)
        let pad: CGFloat = 24, innerW = colW - pad * 2
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false

        func lbl(_ s: String, _ size: CGFloat, _ w: NSFont.Weight, _ c: NSColor, lineSpacing: CGFloat = 0, width: CGFloat) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: s)
            l.font = .systemFont(ofSize: size, weight: w); l.textColor = c
            l.translatesAutoresizingMaskIntoConstraints = false
            if lineSpacing > 0 {
                let p = NSMutableParagraphStyle(); p.lineSpacing = lineSpacing
                l.attributedStringValue = NSAttributedString(string: s,
                    attributes: [.font: l.font!, .foregroundColor: c, .paragraphStyle: p])
            }
            l.widthAnchor.constraint(equalToConstant: width).isActive = true
            return l
        }
        func sectionHeader(_ s: String, _ c: NSColor = .tertiaryLabelColor) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 10.5, weight: .semibold); l.textColor = c
            l.translatesAutoresizingMaskIntoConstraints = false
            return l
        }

        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(lbl(d?.title ?? "Generated cover art", 19, .bold, .labelColor, width: innerW))
        if let a = d?.artist, !a.isEmpty {
            stack.setCustomSpacing(3, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(lbl(a, 14, .regular, .secondaryLabelColor, width: innerW))
        }
        let facts = [d?.date, d?.origin, d?.medium, d?.dimensions].compactMap { $0 }.filter { !$0.isEmpty }
        if !facts.isEmpty {
            stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(lbl(facts.joined(separator: " · "), 11.5, .regular, .secondaryLabelColor, lineSpacing: 2, width: innerW))
        }
        if let desc = d?.description, !desc.isEmpty {
            stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)
            let ah = sectionHeader("ABOUT THIS PAINTING"); stack.addArrangedSubview(ah)
            stack.setCustomSpacing(7, after: ah)
            stack.addArrangedSubview(lbl(desc, 13, .regular, NSColor.labelColor.withAlphaComponent(0.9), lineSpacing: 3, width: innerW))
        }

        let whyBox = NSView()
        whyBox.wantsLayer = true
        whyBox.layer?.cornerRadius = 10
        whyBox.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        whyBox.translatesAutoresizingMaskIntoConstraints = false
        let whyHdr = sectionHeader("WHY THIS PAINTING FOR THIS SKILL", .controlAccentColor)
        let whyText = (d?.why).flatMap { $0.isEmpty ? nil : $0 } ?? "This skill uses a generated cover (no museum painting matched)."
        let whyLbl = lbl(whyText, 13.5, .medium, .labelColor, lineSpacing: 2, width: innerW - 28)
        let whyStack = NSStackView(views: [whyHdr, whyLbl])
        whyStack.orientation = .vertical; whyStack.alignment = .leading; whyStack.spacing = 6
        whyStack.translatesAutoresizingMaskIntoConstraints = false
        whyBox.addSubview(whyStack)
        NSLayoutConstraint.activate([
            whyStack.topAnchor.constraint(equalTo: whyBox.topAnchor, constant: 12),
            whyStack.leadingAnchor.constraint(equalTo: whyBox.leadingAnchor, constant: 14),
            whyStack.trailingAnchor.constraint(equalTo: whyBox.trailingAnchor, constant: -14),
            whyStack.bottomAnchor.constraint(equalTo: whyBox.bottomAnchor, constant: -12),
            whyBox.widthAnchor.constraint(equalToConstant: innerW),
        ])
        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(whyBox)

        box.addSubview(stack)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: colW),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: pad),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -pad),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -pad),
        ])
        return box
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

        // Slash command card: the command as a monospace caption, then a Copy button (so the
        // command — the whole point — is never truncated inside the button).
        let slug = NSTextField(labelWithString: skill.initiator)
        slug.font = .monospacedSystemFont(ofSize: 12.5, weight: .medium)
        slug.textColor = .labelColor
        slug.lineBreakMode = .byTruncatingMiddle
        slug.translatesAutoresizingMaskIntoConstraints = false
        let copyBtn = sidebarButton("Copy command", "doc.on.clipboard", #selector(copySlashTapped), prominent: true)
        let cmdStack = NSStackView(views: [slug, copyBtn])
        cmdStack.orientation = .vertical; cmdStack.alignment = .leading; cmdStack.spacing = 9
        cmdStack.translatesAutoresizingMaskIntoConstraints = false
        addCard(card("Slash command", cmdStack))
        slug.widthAnchor.constraint(equalTo: cmdStack.widthAnchor).isActive = true
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
