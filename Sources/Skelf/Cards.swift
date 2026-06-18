// Grid item views: the painting art view, row thumbnail, skill + folder cards, and the glass controls.

import AppKit
import SwiftUI
import Observation
import QuartzCore
import CoreServices
import ServiceManagement
import Carbon.HIToolbox

final class SkillArtView: NSView {
    private let imageLayer = CALayer()
    private let scrim = CAGradientLayer()
    var showScrim = true { didSet { scrim.isHidden = !showScrim } }
    private static var gradientCache: [String: CGImage] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        // A strong, FIXED bottom scrim so the name/description stay legible regardless of how
        // light the painting is (this is applied identically to every card).
        scrim.startPoint = CGPoint(x: 0.5, y: 0.0); scrim.endPoint = CGPoint(x: 0.5, y: 1.0)
        scrim.colors = [NSColor.black.withAlphaComponent(0.92).cgColor,
                        NSColor.black.withAlphaComponent(0.80).cgColor,
                        NSColor.black.withAlphaComponent(0.30).cgColor,
                        NSColor.clear.cgColor]
        scrim.locations = [0.0, 0.32, 0.58, 1.0]
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(scrim)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); imageLayer.frame = bounds; scrim.frame = bounds }

    func setGradient(_ name: String, monogram: Bool = true) {
        imageLayer.contents = Self.gradientImage(name, monogram: monogram)
    }
    func setAvatar(_ image: NSImage) {
        var r = CGRect(origin: .zero, size: image.size)
        imageLayer.contents = image.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }
    func setFavoritesArt() { imageLayer.contents = Self.favoritesImage() }
    func setThemedFallback(_ skill: Skill) { imageLayer.contents = Self.themedImage(skill) }
    func setMosaic(_ cg: CGImage) { imageLayer.contents = cg }

    // An album-cover-style 2×2 collage of a custom folder's skill art (over a gradient that
    // shows through any empty quadrants).
    static func mosaicImage(_ images: [CGImage], seed: String) -> CGImage {
        let size = CGSize(width: 320, height: 420)
        let img = NSImage(size: size)
        img.lockFocus()
        let cols = Palette.gradientColors(seed).compactMap { NSColor(cgColor: $0) }
        if cols.count >= 2, let g = NSGradient(starting: cols[0], ending: cols[1]) {
            g.draw(in: NSRect(origin: .zero, size: size), angle: 55)
        }
        let hw = size.width / 2, hh = size.height / 2
        let quads = [NSRect(x: 0, y: hh, width: hw, height: hh), NSRect(x: hw, y: hh, width: hw, height: hh),
                     NSRect(x: 0, y: 0, width: hw, height: hh), NSRect(x: hw, y: 0, width: hw, height: hh)]
        // A single skill fills the whole tile; otherwise lay up to four into the quadrants.
        if images.count == 1 {
            drawAspectFill(images[0], in: NSRect(origin: .zero, size: size))
        } else {
            for (i, cg) in images.prefix(4).enumerated() { drawAspectFill(cg, in: quads[i]) }
        }
        img.unlockFocus()
        var r = CGRect(origin: .zero, size: size)
        return img.cgImage(forProposedRect: &r, context: nil, hints: nil) ?? .empty
    }
    private static func drawAspectFill(_ cg: CGImage, in rect: NSRect) {
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        let s = max(rect.width / iw, rect.height / ih)
        let w = iw * s, h = ih * s
        NSImage(cgImage: cg, size: NSSize(width: iw, height: ih))
            .draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    // Generated per-skill fallback art: a gradient seeded by the skill's id (so it's
    // unique to that skill) overlaid with a faint purpose-matched icon.
    private static var themedCache: [String: CGImage] = [:]
    static func themedImage(_ skill: Skill) -> CGImage {
        if let c = themedCache[skill.id] { return c }
        let size = CGSize(width: 320, height: 420)
        let img = NSImage(size: size)
        img.lockFocus()
        let cols = Palette.gradientColors(skill.id).compactMap { NSColor(cgColor: $0) }
        if cols.count >= 2, let g = NSGradient(starting: cols[0], ending: cols[1]) {
            g.draw(in: NSRect(origin: .zero, size: size), angle: 55)
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: size.width * 0.34, weight: .semibold)
            .applying(.init(hierarchicalColor: .white))
        if let icon = NSImage(systemSymbolName: artSymbol(for: skill), accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            let p = NSPoint(x: (size.width - icon.size.width) / 2, y: size.height * 0.44)
            icon.draw(at: p, from: .zero, operation: .sourceOver, fraction: 0.30)
        }
        img.unlockFocus()
        var r = CGRect(origin: .zero, size: size)
        let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) ?? CGImage.empty
        themedCache[skill.id] = cg
        return cg
    }

    // A deliberately distinct look for the special "Favorites" folder: a warm
    // amber→rose gradient with a big translucent star — unlike any avatar/gradient card.
    private static var favoritesCache: CGImage?
    static func favoritesImage() -> CGImage {
        if let c = favoritesCache { return c }
        let size = CGSize(width: 320, height: 420)
        let img = NSImage(size: size)
        img.lockFocus()
        let c0 = NSColor(calibratedRed: 1.00, green: 0.66, blue: 0.20, alpha: 1)   // amber
        let c1 = NSColor(calibratedRed: 0.95, green: 0.26, blue: 0.46, alpha: 1)   // rose
        if let g = NSGradient(starting: c0, ending: c1) { g.draw(in: NSRect(origin: .zero, size: size), angle: 62) }
        let star = "★" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size.width * 0.62, weight: .black),
            .foregroundColor: NSColor.white.withAlphaComponent(0.22)]
        let ss = star.size(withAttributes: attrs)
        star.draw(at: NSPoint(x: (size.width - ss.width) / 2, y: size.height * 0.40), withAttributes: attrs)
        img.unlockFocus()
        var r = CGRect(origin: .zero, size: size)
        favoritesCache = img.cgImage(forProposedRect: &r, context: nil, hints: nil)
        return favoritesCache ?? CGImage.empty
    }

    static func gradientImage(_ name: String, monogram: Bool) -> CGImage {
        let key = name + (monogram ? "#m" : "")
        if let c = gradientCache[key] { return c }
        let size = CGSize(width: 320, height: 420)
        let img = NSImage(size: size)
        img.lockFocus()
        let cols = Palette.gradientColors(name).compactMap { NSColor(cgColor: $0) }
        if cols.count >= 2, let g = NSGradient(starting: cols[0], ending: cols[1]) {
            g.draw(in: NSRect(origin: .zero, size: size), angle: 55)
        }
        if monogram {
            let initials = Palette.initials(name) as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size.width * 0.46, weight: .heavy),
                .foregroundColor: NSColor.white.withAlphaComponent(0.17)]
            let ss = initials.size(withAttributes: attrs)
            initials.draw(at: NSPoint(x: (size.width - ss.width) / 2, y: size.height * 0.46), withAttributes: attrs)
        }
        img.unlockFocus()
        var r = CGRect(origin: .zero, size: size)
        return img.cgImage(forProposedRect: &r, context: nil, hints: nil) ?? CGImage.empty
    }
}

private extension CGImage {
    static var empty: CGImage {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
}

// A small rounded thumbnail for menu-bar popover rows (a skill's painting, or a folder's
// creator avatar) — same art the grid cards use, shrunk to a 30pt square.
final class RowThumb: NSView {
    private let img = CALayer()
    override init(frame f: NSRect) {
        super.init(frame: f)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        img.contentsGravity = .resizeAspectFill
        img.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(img)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); img.frame = bounds }
    func setCG(_ c: CGImage?) { img.contents = c }
    func setImage(_ image: NSImage) {
        var r = CGRect(origin: .zero, size: image.size)
        img.contents = image.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }
}

// The card's root view: rounded, with a soft drop shadow that fades in on hover.
final class CardRootView: NSView {
    var corner: CGFloat = 22
    var onLayout: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        layer?.shadowRadius = 16
        layer?.shadowOpacity = 0
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: corner, cornerHeight: corner, transform: nil)
        onLayout?()
    }
}

// A Liquid-Glass circular control overlaid on a card (favorite / ⋯).
// A real Liquid-Glass circular control overlaid on a card (favorite / ⋯). To keep a
// gridful of them performant, the card groups its glass controls inside an
// NSGlassEffectContainerView (see makeGlassControls) so they share ONE backdrop
// sampling pass instead of one each.
final class GlassCircleButton: NSView {
    let button = NSButton()
    let glass = NSGlassEffectView()
    init(symbol: String, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imageScaling = .scaleProportionallyDown
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.contentTintColor = .white
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        button.target = target
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = 15
        if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
        glass.contentView = button
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 30),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// Group glass controls into one NSGlassEffectContainerView → a single sampling pass.
// container.spacing = 0 keeps each control a distinct perfect circle (no liquid merge).
func makeGlassControls(_ circles: [GlassCircleButton], spacing: CGFloat = 7) -> NSView {
    let row = NSStackView(views: circles)
    row.orientation = .horizontal
    row.spacing = spacing
    row.translatesAutoresizingMaskIntoConstraints = false
    let container = NSGlassEffectContainerView()
    container.spacing = 0
    container.contentView = row
    container.translatesAutoresizingMaskIntoConstraints = false
    return container
}

// MARK: - Grid tile (skill card — creator avatar background, product-card style)

final class SkillGridItem: NSCollectionViewItem {
    private let art = SkillArtView()
    private var favCircle: GlassCircleButton!
    private var menuCircle: GlassCircleButton!
    private let nameLabel = NSTextField(labelWithString: "")
    private let descLabel = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton()
    private var hovering = false
    private var artKey = ""
    private(set) var skillId = ""
    private var skill: Skill?            // for the Liquid Glass hover tip
    private var isFav = false
    var onMenu: ((NSView) -> Void)?
    var onToggleFavorite: (() -> Void)?
    var onCopy: (() -> Void)?

    override func loadView() {
        let root = CardRootView()
        // Tell the wrapping description label its real width so it wraps to 2 lines instead
        // of computing a single-line intrinsic height and truncating.
        root.onLayout = { [weak self, weak root] in
            guard let self = self, let root = root else { return }
            let w = max(0, root.bounds.width - 28)
            if abs(self.descLabel.preferredMaxLayoutWidth - w) > 0.5 { self.descLabel.preferredMaxLayoutWidth = w }
        }
        art.translatesAutoresizingMaskIntoConstraints = false
        art.layer?.cornerRadius = 22
        root.addSubview(art)

        favCircle = GlassCircleButton(symbol: "star", target: self, action: #selector(favClicked))
        menuCircle = GlassCircleButton(symbol: "ellipsis", target: self, action: #selector(menuClicked))
        let controls = makeGlassControls([favCircle, menuCircle])   // one shared glass sampling pass
        root.addSubview(controls)

        nameLabel.font = .systemFont(ofSize: 17, weight: .bold)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(nameLabel)

        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = NSColor.white.withAlphaComponent(0.82)
        descLabel.maximumNumberOfLines = 2
        descLabel.lineBreakMode = .byWordWrapping       // wrap to 2 lines…
        descLabel.cell?.truncatesLastVisibleLine = true // …then ellipsize the 2nd
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(descLabel)

        copyButton.isBordered = false
        copyButton.wantsLayer = true
        copyButton.layer?.cornerRadius = 19
        copyButton.layer?.backgroundColor = NSColor.white.cgColor
        copyButton.bezelStyle = .regularSquare
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        setCopyTitle("Copy")
        root.addSubview(copyButton)

        NSLayoutConstraint.activate([
            art.topAnchor.constraint(equalTo: root.topAnchor),
            art.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            art.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            art.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            controls.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            controls.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),

            copyButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            copyButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            copyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            copyButton.heightAnchor.constraint(equalToConstant: 40),

            descLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            descLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            descLabel.heightAnchor.constraint(equalToConstant: 32),   // a fixed 2-line zone
            descLabel.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -10),

            nameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            nameLabel.bottomAnchor.constraint(equalTo: descLabel.topAnchor, constant: -6),
            nameLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
        ])
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        root.addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
        view = root
    }

    private func setCopyTitle(_ s: String) {
        copyButton.attributedTitle = NSAttributedString(string: s,
            attributes: [.foregroundColor: NSColor.black, .font: NSFont.systemFont(ofSize: 14, weight: .bold)])
    }

    func configure(_ skill: Skill, isFavorite: Bool) {
        skillId = skill.id
        self.skill = skill
        artKey = skill.id
        // Each skill card wears its own unique art: the mapped Creative-Commons image when
        // available, otherwise an immediate generated themed fallback (gradient + icon).
        if let img = ArtStore.shared.cached(skill.id) {
            art.setAvatar(img)
        } else {
            art.setThemedFallback(skill)
            let key = skill.id
            ArtStore.shared.fetch(skill) { [weak self] img in
                guard let self = self, self.artKey == key, let img = img else { return }
                self.art.setAvatar(img)   // upgrade the fallback to the real CC art
            }
        }
        nameLabel.stringValue = skill.name
        descLabel.stringValue = skill.description.isEmpty ? "No description in SKILL.md." : skill.description
        setFavorite(isFavorite, animated: false)
        setCopyTitle("Copy")
        view.alphaValue = skill.enabled ? 1.0 : 0.62
        resetHover()                        // the hover info is now a Liquid Glass tip (no system tooltip)
    }

    /// Update the star, optionally with a springy pop (used when the user toggles it).
    func setFavorite(_ on: Bool, animated: Bool) {
        isFav = on
        favCircle.button.image = NSImage(systemSymbolName: on ? "star.fill" : "star",
                                         accessibilityDescription: on ? "Favorited" : "Favorite")
        favCircle.button.contentTintColor = on ? .systemYellow : .white
        if animated { springPop(favCircle.layer, from: on ? 0.5 : 0.86, damping: 9, stiffness: 380) }
    }

    @objc private func favClicked() {
        setFavorite(!isFav, animated: true)   // animate in place first…
        onToggleFavorite?()                    // …then persist (no destructive grid reload)
    }
    @objc private func menuClicked() { onMenu?(menuCircle) }
    @objc private func copyClicked() {
        onCopy?()
        springPop(copyButton.layer, from: 0.9)
        setCopyTitle("Copied ✓")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in self?.setCopyTitle("Copy") }
    }

    func pressPop() { SkillHoverTip.shared.cancel(); springPop(view.layer, from: 0.97) }

    private func resetHover() {
        hovering = false
        view.layer?.transform = CATransform3DIdentity
        view.layer?.shadowOpacity = 0
        view.layer?.zPosition = 0
    }
    override func mouseEntered(with event: NSEvent) {
        hovering = true; applyHover()
        if let s = skill, let win = view.window {
            let frame = win.convertToScreen(view.convert(view.bounds, to: nil))
            SkillHoverTip.shared.schedule(for: s, cardScreenFrame: frame, on: win.screen)
        }
    }
    override func mouseExited(with event: NSEvent) { hovering = false; applyHover(); SkillHoverTip.shared.cancel() }
    private func applyHover() {
        guard let l = view.layer else { return }
        l.zPosition = hovering ? 1 : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: hovering ? .easeOut : .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            l.transform = hovering ? centerScale(l, 1.04) : CATransform3DIdentity
            l.shadowOpacity = hovering ? 0.42 : 0.0
        }
    }
    override var isSelected: Bool {
        didSet {
            art.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
            art.layer?.borderWidth = isSelected ? 2 : 0
        }
    }
}

// MARK: - Folder tile (same card shape, gradient + folder glyph)

final class FolderGridItem: NSCollectionViewItem {
    private let art = SkillArtView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private var menuCircle: GlassCircleButton!
    private var hovering = false
    private var artKey = ""
    var onMenu: ((NSView) -> Void)?

    override func loadView() {
        let root = CardRootView()
        art.translatesAutoresizingMaskIntoConstraints = false
        art.layer?.cornerRadius = 22
        root.addSubview(art)

        menuCircle = GlassCircleButton(symbol: "ellipsis", target: self, action: #selector(menuClicked))
        let controls = makeGlassControls([menuCircle])   // same glass treatment as skill cards
        root.addSubview(controls)

        nameLabel.font = .systemFont(ofSize: 17, weight: .bold)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(nameLabel)

        countLabel.font = .systemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(countLabel)

        NSLayoutConstraint.activate([
            art.topAnchor.constraint(equalTo: root.topAnchor),
            art.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            art.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            art.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            controls.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            controls.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),

            countLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            countLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            countLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            nameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            nameLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            nameLabel.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -4),
        ])
        root.addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
        view = root
    }

    // The special "Favorites" folder — distinct art, no ⋯ menu.
    func configureFavorites(count: Int) {
        artKey = "__favorites__"
        art.setFavoritesArt()
        nameLabel.stringValue = "Favorites"
        countLabel.stringValue = "\(count) skill\(count == 1 ? "" : "s")"
        menuCircle.isHidden = true
        resetHover()
    }

    func configure(_ node: FolderStore.Node, inMenuBar: Bool, mosaicSkills: [Skill] = []) {
        menuCircle.isHidden = false
        // creator folders wear the creator's avatar; custom folders show a 2×2 mosaic of
        // their skills' paintings (album-cover style); empty folders fall back to a gradient.
        if let creator = node.autoCreator {
            artKey = creator
            if let img = AvatarStore.shared.cached(creator) { art.setAvatar(img) }
            else {
                art.setGradient(node.name)
                let key = creator
                AvatarStore.shared.fetch(creator) { [weak self] img in
                    guard let self = self, self.artKey == key, let img = img else { return }
                    self.art.setAvatar(img)
                }
            }
        } else if !mosaicSkills.isEmpty {
            artKey = "mosaic:" + node.id
            rebuildMosaic(node: node, skills: Array(mosaicSkills.prefix(4)))
        } else {
            artKey = "grad:" + node.name
            art.setGradient(node.name)
        }
        nameLabel.stringValue = node.name
        let s = node.skills.count, f = node.folders.count
        var parts: [String] = []
        if f > 0 { parts.append("\(f) folder\(f == 1 ? "" : "s")") }
        parts.append("\(s) skill\(s == 1 ? "" : "s")")
        countLabel.stringValue = parts.joined(separator: " · ")
        resetHover()
    }

    // Compose the folder's mosaic from its skills' art (cached painting, else themed art),
    // then fetch any missing paintings and recompose when they land.
    private func rebuildMosaic(node: FolderStore.Node, skills: [Skill]) {
        let key = "mosaic:" + node.id
        let imgs: [CGImage] = skills.map { s in
            if let img = ArtStore.shared.cached(s.id) {
                var r = CGRect(origin: .zero, size: img.size)
                return img.cgImage(forProposedRect: &r, context: nil, hints: nil) ?? SkillArtView.themedImage(s)
            }
            return SkillArtView.themedImage(s)
        }
        art.setMosaic(SkillArtView.mosaicImage(imgs, seed: node.name))
        for s in skills where ArtStore.shared.cached(s.id) == nil {
            ArtStore.shared.fetch(s) { [weak self] _ in
                guard let self = self, self.artKey == key else { return }
                self.rebuildMosaic(node: node, skills: skills)
            }
        }
    }

    @objc private func menuClicked() { onMenu?(menuCircle) }
    func pressPop() { springPop(view.layer, from: 0.97) }

    private func resetHover() {
        hovering = false
        view.layer?.transform = CATransform3DIdentity
        view.layer?.shadowOpacity = 0
        view.layer?.zPosition = 0
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; applyHover() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyHover() }
    private func applyHover() {
        guard let l = view.layer else { return }
        l.zPosition = hovering ? 1 : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: hovering ? .easeOut : .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            l.transform = hovering ? centerScale(l, 1.04) : CATransform3DIdentity
            l.shadowOpacity = hovering ? 0.42 : 0.0
        }
    }
    override var isSelected: Bool {
        didSet {
            art.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
            art.layer?.borderWidth = isSelected ? 2 : 0
        }
    }
}

// MARK: - Detail screen

// Semantic-font helpers (respect the system text-size ramp instead of magic numbers).
