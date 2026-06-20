// The two-column skill detail view (banner + SKILL.md + sticky sidebar) and menu helpers.

import AppKit
import SwiftUI
import Observation
import QuartzCore
import CoreServices
import ServiceManagement
import Carbon.HIToolbox

final class SkillDetailView: NSView, NSGestureRecognizerDelegate {
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
    private var headerBack: GlassCircleButton!
    private var headerCopy: GlassCircleButton!
    private var headerFav: GlassCircleButton!
    private weak var folderAnchor: NSView?

    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let aiSummaryBox = NSView()                                   // on-device plain-English summary
    private let aiSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let bodyText = NSTextView()   // SKILL.md body — scrolls internally for big files
    private let sidebarStack = NSStackView()
    private weak var leftColumn: NSView?   // left content column + sidebar — for the open cascade
    private weak var sideColumn: NSView?
    private var lastAnimatedId = ""

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
        banner.toolTip = "Click to view the full image"
        let bannerTap = NSClickGestureRecognizer(target: self, action: #selector(bannerClicked))
        bannerTap.delegate = self      // …but never when a header glass control is what's clicked
        banner.addGestureRecognizer(bannerTap)
        bannerName.font = .systemFont(ofSize: 28, weight: .bold)   // the page title — clearly largest
        bannerName.textColor = .white
        bannerName.lineBreakMode = .byTruncatingTail
        bannerName.shadow = legibilityShadow()
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

        // The page's topbar now lives in the banner: back (left); Copy / Favorite / Add-to-Folder
        // (right). Glass circles stay legible over the artwork, matching the cards' controls.
        headerBack = GlassCircleButton(symbol: "chevron.left", target: self, action: #selector(backTapped))
        headerBack.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(headerBack)
        headerCopy = GlassCircleButton(symbol: "doc.on.doc", target: self, action: #selector(headerCopyTapped))
        headerFav = GlassCircleButton(symbol: "star", target: self, action: #selector(favoriteTapped))
        let headerFolder = GlassCircleButton(symbol: "folder.badge.plus", target: self, action: #selector(organizeTapped))
        folderAnchor = headerFolder
        let headerActions = makeGlassControls([headerCopy, headerFav, headerFolder])
        banner.addSubview(headerActions)
        // The header controls now live in the transparent window toolbar (leveled with the traffic
        // lights). Keep these wired but hidden so the banner shows clean art behind the toolbar.
        headerBack.isHidden = true; headerActions.isHidden = true

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
        leftColumn = leftBox

        // Summary block (the description), pinned at the top.
        let summaryHeader = NSTextField(labelWithString: "SUMMARY")
        summaryHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        summaryHeader.textColor = .secondaryLabelColor
        summaryHeader.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = .systemFont(ofSize: 14.5)
        summaryLabel.textColor = .labelColor
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        // An accent-tinted callout under the raw description holding the model's plain-English
        // take. Hidden until a summary arrives (and stays hidden when AI is unavailable).
        aiSummaryBox.wantsLayer = true
        aiSummaryBox.layer?.cornerRadius = 10
        aiSummaryBox.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
        aiSummaryBox.translatesAutoresizingMaskIntoConstraints = false
        aiSummaryBox.isHidden = true
        let aiHdr = NSTextField(labelWithString: "IN PLAIN ENGLISH")
        aiHdr.font = .systemFont(ofSize: 10, weight: .semibold); aiHdr.textColor = .controlAccentColor
        aiHdr.translatesAutoresizingMaskIntoConstraints = false
        aiSummaryLabel.font = .systemFont(ofSize: 13.5)
        aiSummaryLabel.textColor = NSColor.labelColor.withAlphaComponent(0.95)
        aiSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        let aiStack = NSStackView(views: [aiHdr, aiSummaryLabel])
        aiStack.orientation = .vertical; aiStack.alignment = .leading; aiStack.spacing = 5
        aiStack.translatesAutoresizingMaskIntoConstraints = false
        aiSummaryBox.addSubview(aiStack)
        NSLayoutConstraint.activate([
            aiStack.topAnchor.constraint(equalTo: aiSummaryBox.topAnchor, constant: 11),
            aiStack.leadingAnchor.constraint(equalTo: aiSummaryBox.leadingAnchor, constant: 13),
            aiStack.trailingAnchor.constraint(equalTo: aiSummaryBox.trailingAnchor, constant: -13),
            aiStack.bottomAnchor.constraint(equalTo: aiSummaryBox.bottomAnchor, constant: -11)
        ])

        let summaryBlock = NSStackView(views: [summaryHeader, summaryLabel, aiSummaryBox])
        summaryBlock.orientation = .vertical; summaryBlock.alignment = .leading; summaryBlock.spacing = 6
        summaryBlock.setCustomSpacing(12, after: summaryLabel)
        summaryBlock.translatesAutoresizingMaskIntoConstraints = false
        leftBox.addSubview(summaryBlock)
        aiSummaryBox.widthAnchor.constraint(equalTo: summaryBlock.widthAnchor).isActive = true

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
            bodyScroll.bottomAnchor.constraint(equalTo: readmeCard.bottomAnchor)
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
        sideColumn = sidebarScroll
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
            banner.heightAnchor.constraint(equalToConstant: 230),
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
            headerBack.topAnchor.constraint(equalTo: banner.topAnchor, constant: 16),    // below the title-bar drag region
            headerBack.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 84),  // clear the traffic lights
            headerActions.topAnchor.constraint(equalTo: banner.topAnchor, constant: 16),
            headerActions.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -16),

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
            sidebarStack.bottomAnchor.constraint(lessThanOrEqualTo: sideDoc.bottomAnchor, constant: -24)
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
            stack.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -14)
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
        // Same tactile feel as the cards' Copy button: hover pop, snappy press, spring-back on
        // release. centerScale scales around the centre so the rounded bezel doesn't drift.
        let b = AnimatedButton(frame: .zero)
        b.title = " " + title
        b.target = self
        b.action = action
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.imagePosition = .imageLeading
        b.bezelStyle = .rounded
        b.controlSize = .large
        b.translatesAutoresizingMaskIntoConstraints = false
        if prominent { b.keyEquivalent = "\r" }
        return b
    }

    func configure(_ skill: Skill, isFavorite: Bool) {
        let isNewSkill = skill.id != lastAnimatedId
        lastAnimatedId = skill.id
        self.skill = skill
        artToken += 1
        let token = artToken
        let creator = skill.source.contains("/") ? skill.source.split(separator: "/").first.map(String.init) : nil
        // The header banner wears the skill's own art (same as its card); the Source
        // sidebar below keeps the creator avatar.
        if let img = ArtStore.shared.cached(skill.id) { banner.setAvatar(img) } else {
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

        // On-device plain-English summary (Foundation Models) — additive, async, cached in
        // SkillFinder. Hidden when AI is unavailable or generation fails; the raw description
        // above always stands on its own.
        aiSummaryBox.isHidden = true
        if SkillFinder.shared.isAvailable {
            Task { @MainActor [weak self] in
                guard let summary = await SkillFinder.shared.summary(for: skill) else { return }
                guard let self = self, self.skill?.id == sid else { return }   // still showing this skill
                self.aiSummaryLabel.stringValue = summary.whatItDoes + " " + summary.whenToUse
                self.aiSummaryBox.isHidden = false
            }
        }
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
        if isNewSkill { animateContentIn() }
    }

    // A gentle staggered entrance when a skill opens: banner, then the left column, then the
    // sidebar cascade up and fade in (ease-out, ≤ 340ms; matches the grid's open transition).
    private func animateContentIn() {
        guard !AppSettings.shared.reduceMotion else { return }
        let cols: [(NSView?, TimeInterval)] = [(banner, 0), (leftColumn, 0.05), (sideColumn, 0.11)]
        for (v, delay) in cols {
            guard let l = v?.layer else { continue }
            let start = CATransform3DMakeTranslation(0, -16, 0)
            let tA = CABasicAnimation(keyPath: "transform"); tA.fromValue = start; tA.toValue = CATransform3DIdentity
            let oA = CABasicAnimation(keyPath: "opacity"); oA.fromValue = 0; oA.toValue = 1
            for a in [tA, oA] {
                a.duration = 0.34
                a.timingFunction = CAMediaTimingFunction(name: .easeOut)
                a.beginTime = CACurrentMediaTime() + delay
                a.fillMode = .backwards
            }
            l.add(tA, forKey: "openInT"); l.add(oA, forKey: "openInO")
        }
    }

    private static var mdCache: [String: NSAttributedString] = [:]
    private func setBody(_ attr: NSAttributedString) {
        bodyText.textStorage?.setAttributedString(attr)
        bodyText.scroll(NSPoint(x: 0, y: 0))   // reset scroll to top for the new skill
    }

    // Clicking the banner → a small, FIXED-footprint floating Liquid-Glass panel that frames the
    // Don't open the artwork popup when the click lands on a header glass control.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        var v = banner.hitTest(banner.convert(event.locationInWindow, from: nil))
        while let cur = v { if cur is GlassCircleButton { return false }; v = cur.superview }
        return true
    }

    // image at its own aspect ratio (SwiftUI `ArtworkPopupView`, with a Metal ripple shader).
    private var paintingPanel: NSPanel?
    @objc private func bannerClicked() {
        guard let skill = skill else { return }
        let img = ArtStore.shared.cached(skill.id) ?? Self.fallbackImage(skill)
        // Fixed footprint: the image's LONGEST side is `maxSide`, ratio preserved (capped to screen).
        let aspect = img.size.width > 0 ? img.size.height / img.size.width : 0.66
        let vf = (self.window?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxSide: CGFloat = min(680, min(vf.width, vf.height) - 120)
        let iw = (aspect > 1 ? maxSide / aspect : maxSide).rounded()
        let ih = (aspect > 1 ? maxSide : maxSide * aspect).rounded()
        let pad: CGFloat = 5, radius: CGFloat = 16
        let w = iw + pad * 2, h = ih + pad * 2

        let host = NSHostingView(rootView: ArtworkPopupView(image: img, imageSize: CGSize(width: iw, height: ih)))
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)
        host.autoresizingMask = [.width, .height]

        // The Liquid-Glass frame shows through the SwiftUI view's padding.
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        glass.cornerRadius = radius
        glass.contentView = host

        // A container with a shadow that follows the ROUNDED corners. (A borderless window's own
        // shadow is square, so its corners poke out past the rounded glass — the "sharp points".)
        // The panel is the card plus a margin for the shadow to spread into.
        let margin: CGFloat = 36
        let pw = w + margin * 2, ph = h + margin * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: pw, height: ph))
        container.wantsLayer = true
        glass.frame = NSRect(x: margin, y: margin, width: w, height: h)
        let shadowLayer = CALayer()
        shadowLayer.frame = glass.frame
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.5
        shadowLayer.shadowRadius = 22
        shadowLayer.shadowOffset = CGSize(width: 0, height: -10)
        shadowLayer.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: NSSize(width: w, height: h)),
                                        cornerWidth: radius, cornerHeight: radius, transform: nil)
        container.layer?.addSublayer(shadowLayer)
        container.addSubview(glass)

        // Borderless (no traffic-light close button); closes on Escape / click-away.
        let panel = PaintingPanel(contentRect: NSRect(x: 0, y: 0, width: pw, height: ph),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false        // the rounded shadowLayer replaces the square window shadow
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentView = container
        panel.centerInScreen(self.window?.screen)
        panel.level = .floating
        panel.makeKeyAndOrderFront(nil)
        panel.animateOpen(scaling: glass.layer)
        paintingPanel = panel
    }

    // A themed gradient stand-in when a skill's space image hasn't been cached yet.
    private static func fallbackImage(_ skill: Skill) -> NSImage {
        let size = NSSize(width: 480, height: 360)
        let img = NSImage(size: size)
        img.lockFocus()
        let cols = Palette.gradientColors(skill.id).compactMap { NSColor(cgColor: $0) }
        (NSGradient(colors: cols.count >= 2 ? cols : [.darkGray, .black]))?
            .draw(in: NSRect(origin: .zero, size: size), angle: -60)
        img.unlockFocus()
        return img
    }

    private func rebuildSidebar(_ skill: Skill, isFavorite: Bool, creator: String?, token: Int) {
        sidebarStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let creatorName = creator ?? "Local"

        // Source card (avatar + repo + View on GitHub)
        let avatar = SkillArtView(); avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.layer?.cornerRadius = 8; avatar.showScrim = false
        avatar.setGradient(creatorName)
        if let creator = creator {
            if let img = AvatarStore.shared.cached(creator) { avatar.setAvatar(img) } else { AvatarStore.shared.fetch(creator) { [weak self] img in
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
        copyCmdButtonRef = copyBtn
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

        // Favorite + Add to Folder moved to the banner header (build()); just sync header state.
        isFav = isFavorite
        setHeaderFavorite(isFavorite)
    }

    private weak var copyCmdButtonRef: NSButton?
    private var isFav = false
    private var copyRevertToken = 0
    private var headerCopyRevertToken = 0
    /// Light favorite-state update (no full reconfigure) — drives the banner header's star.
    func setFavorite(_ on: Bool) {
        isFav = on
        setHeaderFavorite(on)
    }
    private func setHeaderFavorite(_ on: Bool) {
        headerFav?.button.image = NSImage(systemSymbolName: on ? "star.fill" : "star",
                                          accessibilityDescription: on ? "Favorited" : "Favorite")
        headerFav?.button.contentTintColor = on ? .systemYellow : .white
    }

    private func addCard(_ c: NSView) {
        sidebarStack.addArrangedSubview(c)
        c.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true
    }

    @objc private func backTapped() { onBack?() }
    @objc private func favoriteTapped() {
        guard let s = skill else { return }
        isFav.toggle()
        setFavorite(isFav)        // flip the label/star now — don't wait for the SwiftUI round-trip
        onToggleFavorite?(s)      // …then persist
    }
    @objc private func organizeTapped() { if let s = skill { onOrganize?(s, folderAnchor ?? sidebarStack) } }
    @objc private func copySlashTapped() {
        guard let s = skill else { return }
        onCopy?(s)
        flashCopied()
    }
    // The banner header's Copy glass button: copy, then flash a checkmark and settle back.
    @objc private func headerCopyTapped() {
        guard let s = skill else { return }
        onCopy?(s)
        headerCopy.button.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        headerCopyRevertToken += 1
        let tok = headerCopyRevertToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self = self, self.headerCopyRevertToken == tok else { return }
            self.headerCopy.button.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        }
    }
    // Briefly confirm the copy on the "Copy command" button, then settle back (mirrors the card's Copy).
    private func flashCopied() {
        guard let b = copyCmdButtonRef else { return }
        b.title = " Copied ✓"
        copyRevertToken += 1
        let tok = copyRevertToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak b] in
            guard let self = self, self.copyRevertToken == tok else { return }
            b?.title = " Copy command"
        }
    }
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
