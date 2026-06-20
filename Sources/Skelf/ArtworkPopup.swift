// The artwork popup, redesigned in SwiftUI: a small, fixed-footprint card that shows a skill's
// image at its own aspect ratio inside a Liquid-Glass frame, with a Metal ripple shader that
// radiates on appear and on click. Hosted in a floating glass panel by Detail.swift.

import SwiftUI
import AppKit

// MARK: - Ripple (Metal `skelfRipple` shader, driven by a keyframe-animated clock)

private struct RippleModifier: ViewModifier {
    var origin: CGPoint
    var time: TimeInterval
    var amplitude: Double = 10
    var frequency: Double = 14
    var decay: Double = 7
    var speed: Double = 900

    func body(content: Content) -> some View {
        let shader = ShaderLibrary.skelfRipple(
            .float2(origin), .float(time),
            .float(amplitude), .float(frequency), .float(decay), .float(speed)
        )
        content.layerEffect(shader, maxSampleOffset: CGSize(width: amplitude, height: amplitude),
                            isEnabled: time > 0)
    }
}

// Re-runs the ripple (time animates 0 → duration) every time `trigger` flips.
private struct RippleEffect: ViewModifier {
    var origin: CGPoint
    var trigger: Bool
    var duration: TimeInterval = 1.3

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, time in
            view.modifier(RippleModifier(origin: origin, time: time))
        } keyframes: { _ in
            LinearKeyframe(duration, duration: duration)
        }
    }
}

// MARK: - Popup

struct ArtworkPopupView: View {
    let image: NSImage
    let imageSize: CGSize          // the on-screen image size (fixed, ratio-preserving)

    @State private var origin: CGPoint = .zero
    @State private var trigger = false
    @State private var shown = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: imageSize.width, height: imageSize.height)
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
            .modifier(RippleEffect(origin: origin, trigger: trigger))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 1)
            )
            .contentShape(.rect(cornerRadius: 14))
            .onTapGesture { location in
                origin = location
                trigger.toggle()
            }
            .scaleEffect(shown ? 1 : 0.9)
            .opacity(shown ? 1 : 0)
            .padding(8)                // a thin Liquid-Glass frame shows through this inset
            .onAppear {
                origin = CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
                withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { shown = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { trigger.toggle() }
            }
    }
}
