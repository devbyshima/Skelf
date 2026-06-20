// The artwork popup, in SwiftUI: a small, fixed-footprint card that shows a skill's image at
// its own aspect ratio inside a thin Liquid-Glass frame, with a Metal ripple shader that
// radiates on appear and on EVERY click. Hosted in a floating glass panel by Detail.swift.
//
// The ripple is driven by an explicit start `Date` + a TimelineView, NOT keyframeAnimator:
// every tap just stamps a new start time and origin, so it restarts reliably under rapid
// stress-clicking. The shader is applied ONLY while a ripple is in flight — when idle the raw
// image always shows (and the timeline is paused), so a failed shader load can never blank it.

import SwiftUI
import AppKit

struct ArtworkPopupView: View {
    let image: NSImage
    let imageSize: CGSize

    @State private var origin: CGPoint = .zero
    @State private var rippleStart: Date?      // non-nil only while a ripple is animating
    @State private var shown = false
    private let rippleDuration: TimeInterval = 1.2

    var body: some View {
        // Paused (no redraws, raw image) until a ripple is in flight.
        TimelineView(.animation(paused: rippleStart == nil)) { timeline in
            let elapsed = rippleStart.map { timeline.date.timeIntervalSince($0) } ?? rippleDuration
            let active = elapsed >= 0 && elapsed < rippleDuration
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: imageSize.width, height: imageSize.height)
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                .layerEffect(
                    ShaderLibrary.skelfRipple(.float2(origin), .float(elapsed),
                                              .float(10), .float(14), .float(7), .float(900)),
                    maxSampleOffset: CGSize(width: 10, height: 10),
                    isEnabled: active
                )
        }
        .frame(width: imageSize.width, height: imageSize.height)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        )
        .contentShape(.rect(cornerRadius: 12))
        .onTapGesture { location in startRipple(at: location) }
        .scaleEffect(shown ? 1 : 0.9)
        .opacity(shown ? 1 : 0)
        .padding(5)                            // a thin Liquid-Glass frame shows through this inset
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { shown = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                startRipple(at: CGPoint(x: imageSize.width / 2, y: imageSize.height / 2))
            }
        }
    }

    private func startRipple(at point: CGPoint) {
        origin = point
        let now = Date()
        rippleStart = now
        // When this ripple finishes, pause the timeline — unless a later tap restarted it.
        DispatchQueue.main.asyncAfter(deadline: .now() + rippleDuration + 0.05) {
            if rippleStart == now { rippleStart = nil }
        }
    }
}
