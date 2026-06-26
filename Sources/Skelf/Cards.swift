// Grid item views: the painting art view, row thumbnail, skill + folder cards, and the glass controls.

import AppKit
import SwiftUI
import Observation
import QuartzCore
import CoreServices
import ServiceManagement
import Carbon.HIToolbox

// A soft drop shadow that keeps white card/banner text legible over bright or busy artwork.
func legibilityShadow() -> NSShadow {
    let s = NSShadow()
    s.shadowColor = NSColor.black.withAlphaComponent(0.6)
    s.shadowBlurRadius = 4
    s.shadowOffset = NSSize(width: 0, height: -1)
    return s
}

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
    func setAvatar(_ image: NSImage, animated: Bool = false) {
        var r = CGRect(origin: .zero, size: image.size)
        let cg = image.cgImage(forProposedRect: &r, context: nil, hints: nil)
        if animated {
            let fade = CATransition(); fade.type = .fade; fade.duration = 0.45
            imageLayer.add(fade, forKey: "contents")
            imageLayer.contents = cg
            shimmerOnce()                       // a light sweep as the real art lands
        } else {
            imageLayer.contents = cg
        }
    }

    /// A one-shot diagonal highlight sweep across the card (when its art finishes loading).
    func shimmerOnce() {
        guard bounds.width > 1, !AppSettings.shared.reduceMotion else { return }
        let band = CAGradientLayer()
        let w = bounds.width * 0.55
        band.frame = CGRect(x: 0, y: -bounds.height * 0.25, width: w, height: bounds.height * 1.5)
        band.startPoint = CGPoint(x: 0, y: 0.5); band.endPoint = CGPoint(x: 1, y: 0.5)
        band.colors = [NSColor.clear.cgColor, NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.clear.cgColor]
        band.locations = [0, 0.5, 1]
        band.transform = CATransform3DMakeRotation(.pi / 7, 0, 0, 1)
        band.compositingFilter = "screenBlendMode"
        layer?.insertSublayer(band, below: scrim)        // over the art, under the legibility scrim
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -w; sweep.toValue = bounds.width + w
        sweep.duration = 0.85
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        band.add(sweep, forKey: "shimmer")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { band.removeFromSuperlayer() }
    }

    /// Gently zoom only the artwork (not the scrim/labels) — a parallax lift on card hover.
    func setHoverZoom(_ on: Bool) {
        guard !AppSettings.shared.reduceMotion else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            imageLayer.transform = on ? CATransform3DMakeScale(1.06, 1.06, 1) : CATransform3DIdentity
        }
    }
    func resetZoom() { imageLayer.transform = CATransform3DIdentity }
    func setFavoritesArt() { imageLayer.contents = Self.favoritesImage() }
    func setThemedFallback(_ skill: Skill) { imageLayer.contents = Self.themedImage(skill) }
    func setMosaic(_ cg: CGImage) { imageLayer.contents = cg }

    // Shared 320×420 card-art canvas: lockFocus scaffold → CGImage. The `draw` closure does only
    // the unique drawing for each generator.
    private static func render(_ draw: (CGSize) -> Void) -> CGImage {
        let size = CGSize(width: 320, height: 420)
        let img = NSImage(size: size)
        img.lockFocus()
        draw(size)
        img.unlockFocus()
        var r = CGRect(origin: .zero, size: size)
        return img.cgImage(forProposedRect: &r, context: nil, hints: nil) ?? .empty
    }

    // The seed-derived two-stop gradient backdrop shared by the mosaic / themed / gradient cards.
    private static func drawGradient(seed: String, angle: CGFloat, in size: CGSize) {
        let cols = Palette.gradientColors(seed).compactMap { NSColor(cgColor: $0) }
        if cols.count >= 2, let g = NSGradient(starting: cols[0], ending: cols[1]) {
            g.draw(in: NSRect(origin: .zero, size: size), angle: angle)
        }
    }

    // An album-cover-style 2×2 collage of a custom folder's skill art (over a gradient that
    // shows through any empty quadrants).
    static func mosaicImage(_ images: [CGImage], seed: String) -> CGImage {
        render { size in
            drawGradient(seed: seed, angle: 55, in: size)
            let hw = size.width / 2, hh = size.height / 2
            let quads = [NSRect(x: 0, y: hh, width: hw, height: hh), NSRect(x: hw, y: hh, width: hw, height: hh),
                         NSRect(x: 0, y: 0, width: hw, height: hh), NSRect(x: hw, y: 0, width: hw, height: hh)]
            // A single skill fills the whole tile; otherwise lay up to four into the quadrants.
            if images.count == 1 {
                drawAspectFill(images[0], in: NSRect(origin: .zero, size: size))
            } else {
                for (i, cg) in images.prefix(4).enumerated() { drawAspectFill(cg, in: quads[i]) }
            }
        }
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
        let cg = render { size in
            drawGradient(seed: skill.id, angle: 55, in: size)
            let cfg = NSImage.SymbolConfiguration(pointSize: size.width * 0.34, weight: .semibold)
                .applying(.init(hierarchicalColor: .white))
            if let icon = NSImage(systemSymbolName: artSymbol(for: skill), accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) {
                let p = NSPoint(x: (size.width - icon.size.width) / 2, y: size.height * 0.44)
                icon.draw(at: p, from: .zero, operation: .sourceOver, fraction: 0.30)
            }
        }
        themedCache[skill.id] = cg
        return cg
    }

    // A deliberately distinct look for the special "Favorites" folder: a warm
    // amber→rose gradient with a big translucent star — unlike any avatar/gradient card.
    private static var favoritesCache: CGImage?
    static func favoritesImage() -> CGImage {
        if let c = favoritesCache { return c }
        let cg = render { size in
            let c0 = NSColor(calibratedRed: 1.00, green: 0.66, blue: 0.20, alpha: 1)   // amber
            let c1 = NSColor(calibratedRed: 0.95, green: 0.26, blue: 0.46, alpha: 1)   // rose
            if let g = NSGradient(starting: c0, ending: c1) { g.draw(in: NSRect(origin: .zero, size: size), angle: 62) }
            let star = "★" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size.width * 0.62, weight: .black),
                .foregroundColor: NSColor.white.withAlphaComponent(0.22)]
            let ss = star.size(withAttributes: attrs)
            star.draw(at: NSPoint(x: (size.width - ss.width) / 2, y: size.height * 0.40), withAttributes: attrs)
        }
        favoritesCache = cg
        return cg
    }

    static func gradientImage(_ name: String, monogram: Bool) -> CGImage {
        let key = name + (monogram ? "#m" : "")
        if let c = gradientCache[key] { return c }
        return render { size in
            drawGradient(seed: name, angle: 55, in: size)
            if monogram {
                let initials = Palette.initials(name) as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: size.width * 0.46, weight: .heavy),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.17)]
                let ss = initials.size(withAttributes: attrs)
                initials.draw(at: NSPoint(x: (size.width - ss.width) / 2, y: size.height * 0.46), withAttributes: attrs)
            }
        }
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

// An NSButton with tactile press feedback: a quick scale-down while held, easing back on
// release (Disney active-state / squash; ~140ms ease-out, honors Reduce Motion). Used wherever
// a button should feel pressable — card controls, the Copy button, the detail sidebar.
final class AnimatedButton: NSButton {
    // The view to scale on click — defaults to self, but glass controls set this to the visible
    // glass circle (scaling the button *inside* the glass doesn't show through the effect).
    weak var pressScaleTarget: NSView?
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    // Click feedback: a momentary spring-pop (squash to 0.9, overshoot back to rest), driven by the
    // *action* — not a held press. springPop only animates the presentation and never touches the
    // model transform, so the button always returns to full size, even when the click opens a modal
    // menu that eats the mouse-up (which previously left the held scale stuck shrunk).
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        springPop((pressScaleTarget ?? self).layer, from: 0.9)
        return super.sendAction(action, to: target)
    }
}

// A Liquid-Glass circular control overlaid on a card (favorite / ⋯).
// A real Liquid-Glass circular control overlaid on a card (favorite / ⋯). To keep a
// gridful of them performant, the card groups its glass controls inside an
// NSGlassEffectContainerView (see makeGlassControls) so they share ONE backdrop
// sampling pass instead of one each.
final class GlassCircleButton: NSView {
    let button = AnimatedButton()
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
        glass.contentView = button
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 30),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        button.pressScaleTarget = self      // scale the visible glass circle on press
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

// Shared card-tile behaviour: the art view, the hover-lift animation, and the selection
// border — identical across skill and folder tiles. Subclasses build their own layout in
// loadView, set artKey/onMenu, and override mouse tracking (pressPop stays per-subclass).
class CardGridItem: NSCollectionViewItem {
    let art = SkillArtView()
    var hovering = false
    var artKey = ""
    var onMenu: ((NSView) -> Void)?

    func resetHover() {
        hovering = false
        view.layer?.transform = CATransform3DIdentity
        view.layer?.shadowOpacity = 0
        view.layer?.zPosition = 0
        art.resetZoom()
    }
    func applyHover() {
        guard let l = view.layer else { return }
        l.zPosition = hovering ? 1 : 0
        NSAnimationContext.runAnimationGroup { ctx in
            let springBack = !hovering && !AppSettings.shared.reduceMotion   // settle with a gentle overshoot on hover-out
            ctx.duration = springBack ? 0.3 : 0.2
            ctx.timingFunction = springBack
                ? CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1)
                : CAMediaTimingFunction(name: hovering ? .easeOut : .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            l.transform = hovering ? centerScale(l, 1.05) : CATransform3DIdentity
            l.shadowOpacity = hovering ? 0.5 : 0.0
        }
        art.setHoverZoom(hovering)
    }
    override var isSelected: Bool {
        didSet {
            art.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
            art.layer?.borderWidth = isSelected ? 2 : 0
        }
    }
}

final class SkillGridItem: CardGridItem {
    private var favCircle: GlassCircleButton!
    private var menuCircle: GlassCircleButton!
    private let nameLabel = NSTextField(labelWithString: "")
    private let descLabel = NSTextField(wrappingLabelWithString: "")
    private let copyButton = AnimatedButton()
    private(set) var skillId = ""
    private var skill: Skill?            // for the Liquid Glass hover tip
    private var isFav = false
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
        nameLabel.shadow = legibilityShadow()
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(nameLabel)

        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = NSColor.white.withAlphaComponent(0.88)
        descLabel.shadow = legibilityShadow()
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
        copyButton.translatesAutoresizingMaskIntoConstraints = false   // hover/press/spring-back come from AnimatedButton defaults
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
            nameLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14)
        ])
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        root.addTrackingArea(NSTrackingArea(rect: .zero,                  // .mouseMoved → the hover tip follows the pointer
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
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
                self.art.setAvatar(img, animated: true)   // crossfade + shimmer in the real art
            }
        }
        nameLabel.stringValue = skill.name
        descLabel.stringValue = skill.description.isEmpty ? "No description in SKILL.md." : skill.description
        setFavorite(isFavorite, animated: false)
        setCopyTitle("Copy")
        view.alphaValue = skill.enabled ? 1.0 : 0.62
        // The slash command is no longer in a system tooltip; expose it to VoiceOver on the
        // button that copies it (name + description stay readable as the visible labels).
        copyButton.setAccessibilityHelp("Copies \(skill.initiator) to the clipboard")
        resetHover()                        // the hover info is now a Liquid Glass tip
    }

    /// Update the star, optionally with a springy pop (used when the user toggles it).
    func setFavorite(_ on: Bool, animated: Bool) {
        isFav = on
        favCircle.button.image = NSImage(systemSymbolName: on ? "star.fill" : "star",
                                         accessibilityDescription: on ? "Favorited" : "Favorite")
        favCircle.button.contentTintColor = on ? .systemYellow : .white
        if animated {
            springPop(favCircle.layer, from: on ? 0.5 : 0.86, damping: 9, stiffness: 380)
            if on { favoriteBurst() }
        }
    }

    @objc private func favClicked() {
        setFavorite(!isFav, animated: true)   // animate in place first…
        onToggleFavorite?()                    // …then persist (no destructive grid reload)
    }
    @objc private func menuClicked() { onMenu?(menuCircle) }
    @objc private func copyClicked() {
        onCopy?()
        // The click pop (squash + spring back) is handled by AnimatedButton.sendAction.
        setCopyTitle("Copied ✓")
        // A brief green wash confirms the copy, then settles back to white.
        if !AppSettings.shared.reduceMotion, let l = copyButton.layer {
            let flash = CABasicAnimation(keyPath: "backgroundColor")
            flash.fromValue = NSColor(calibratedRed: 0.52, green: 0.86, blue: 0.56, alpha: 1).cgColor
            flash.toValue = NSColor.white.cgColor
            flash.duration = 0.7
            flash.timingFunction = CAMediaTimingFunction(name: .easeOut)
            l.add(flash, forKey: "copyFlash")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in self?.setCopyTitle("Copy") }
    }

    // A quick expanding ring when a skill is favorited (secondary action / follow-through).
    private func favoriteBurst() {
        guard !AppSettings.shared.reduceMotion, let host = favCircle.layer else { return }
        let ring = CAShapeLayer()
        ring.frame = favCircle.bounds
        let r: CGFloat = 11
        ring.path = CGPath(ellipseIn: CGRect(x: favCircle.bounds.midX - r, y: favCircle.bounds.midY - r,
                                             width: r * 2, height: r * 2), transform: nil)
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = NSColor.systemYellow.cgColor
        ring.lineWidth = 2
        host.addSublayer(ring)
        let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = 0.4; scale.toValue = 1.9
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0.9; fade.toValue = 0
        let g = CAAnimationGroup(); g.animations = [scale, fade]; g.duration = 0.5
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(g, forKey: "burst")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { ring.removeFromSuperlayer() }
    }

    func pressPop() { SkillHoverTip.shared.cancel(); springPop(view.layer, from: 0.97) }

    override func mouseEntered(with event: NSEvent) {
        hovering = true; applyHover()
        if let s = skill {
            SkillHoverTip.shared.schedule(for: s, at: NSEvent.mouseLocation, on: view.window?.screen)
            // Warm the on-device model while browsing, and pre-generate this skill's explanation if
            // the pointer dwells — so opening the card shows it instantly instead of cold-starting.
            SkillFinder.shared.prewarm()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self = self, self.hovering, self.skill?.id == s.id else { return }
                Task { _ = await SkillFinder.shared.summary(for: s) }
            }
        }
    }
    override func mouseMoved(with event: NSEvent) { SkillHoverTip.shared.update(cursor: NSEvent.mouseLocation) }
    override func mouseExited(with event: NSEvent) { hovering = false; applyHover(); SkillHoverTip.shared.cancel() }
}

// MARK: - Folder tile (same card shape, gradient + folder glyph)

final class FolderGridItem: CardGridItem {
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private var menuCircle: GlassCircleButton!

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
        nameLabel.shadow = legibilityShadow()
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(nameLabel)

        countLabel.font = .systemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = NSColor.white.withAlphaComponent(0.86)
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.shadow = legibilityShadow()
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
            nameLabel.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -4)
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
            if let img = AvatarStore.shared.cached(creator) { art.setAvatar(img) } else {
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

    override func mouseEntered(with event: NSEvent) { hovering = true; applyHover() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyHover() }
}

// MARK: - Detail screen

// Semantic-font helpers (respect the system text-size ramp instead of magic numbers).
