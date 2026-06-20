// The skill detail's banner — skill art that ripples (on open and on click) with the same Metal
// `skelfRipple` shader the artwork popup uses. The art + legibility scrim are a hosted SwiftUI
// view; the detail stacks its name / status / slash-command labels on top as AppKit subviews.

import SwiftUI
import AppKit

@Observable final class RippleArtModel {
    var image: NSImage?
    var rippleStart: Date?                              // non-nil only while a ripple is in flight
    var unitOrigin = CGPoint(x: 0.5, y: 0.5)            // ripple origin in 0…1 of the view
    var onTap: (() -> Void)?
    let rippleDuration: TimeInterval = 1.2
    private var token = 0

    func ripple(unit: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        guard !AppSettings.shared.reduceMotion else { return }
        unitOrigin = unit
        let now = Date()
        rippleStart = now
        token += 1
        let t = token
        // Pause the timeline once this ripple finishes — unless a later tap restarted it.
        DispatchQueue.main.asyncAfter(deadline: .now() + rippleDuration + 0.05) { [weak self] in
            guard let self, self.token == t else { return }
            self.rippleStart = nil
        }
    }
}

private struct RippleArt: View {
    let model: RippleArtModel

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let origin = CGPoint(x: model.unitOrigin.x * size.width, y: model.unitOrigin.y * size.height)
            ZStack {
                // Paused (raw image, no redraws) until a ripple is in flight.
                TimelineView(.animation(paused: model.rippleStart == nil)) { timeline in
                    let elapsed = model.rippleStart.map { timeline.date.timeIntervalSince($0) } ?? model.rippleDuration
                    let active = elapsed >= 0 && elapsed < model.rippleDuration
                    Group {
                        if let img = model.image {
                            Image(nsImage: img).resizable().interpolation(.high).scaledToFill()
                        } else {
                            Color.black
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .layerEffect(
                        ShaderLibrary.skelfRipple(.float2(origin), .float(elapsed),
                                                  .float(10), .float(14), .float(7), .float(900)),
                        maxSampleOffset: CGSize(width: 10, height: 10),
                        isEnabled: active
                    )
                }
                // Legibility scrim — darkest at the bottom, for the name/status labels.
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.92), location: 0.0),
                    .init(color: .black.opacity(0.80), location: 0.32),
                    .init(color: .black.opacity(0.30), location: 0.58),
                    .init(color: .clear, location: 1.0)
                ], startPoint: .bottom, endPoint: .top)
                .allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(.rect)
            .onTapGesture { loc in
                model.ripple(unit: CGPoint(x: loc.x / max(size.width, 1), y: loc.y / max(size.height, 1)))
                model.onTap?()
            }
        }
    }
}

final class RippleBannerView: NSView {
    let rippleModel = RippleArtModel()
    var onClick: (() -> Void)?                          // fired after the click ripple is kicked off
    private var host: NSHostingView<RippleArt>!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        host = NSHostingView(rootView: RippleArt(model: rippleModel))
        host.safeAreaRegions = []     // fill under the transparent toolbar (no top safe-area inset)
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        rippleModel.onTap = { [weak self] in self?.onClick?() }
    }
    required init?(coder: NSCoder) { fatalError() }

    // Drop-in for the calls the detail used on SkillArtView.
    func setAvatar(_ image: NSImage, animated: Bool = false) { rippleModel.image = image }
    func setThemedFallback(_ skill: Skill) {
        let cg = SkillArtView.themedImage(skill)
        rippleModel.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
    func ripple() { rippleModel.ripple() }
}
