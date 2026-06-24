// The "Update Available" window — the app icon, the new version, the release's rendered notes,
// and Install & Relaunch / Later / Skip. Once installing, the same window shows the download /
// verify / install / relaunch progress in place. Replaces the old NSAlert prompt + floating HUD.

import SwiftUI
import AppKit

@Observable final class UpdateModel {
    enum Phase: Equatable {
        case available
        case downloading(Double)        // 0…1
        case verifying
        case installing
        case relaunching
        case failed(String)

        /// True while a download/install is underway (the window's chrome locks down then).
        var isInstalling: Bool {
            switch self {
            case .available, .failed: return false
            default: return true
            }
        }
    }

    var phase: Phase = .available
    let currentVersion: String
    let newVersion: String
    let notes: String

    var onInstall: () -> Void = {}
    var onSkip: () -> Void = {}
    var onLater: () -> Void = {}
    var onOpenPage: () -> Void = {}

    init(currentVersion: String, newVersion: String, notes: String) {
        self.currentVersion = currentVersion
        self.newVersion = newVersion
        self.notes = notes
    }
}

// MARK: - The window's SwiftUI content

struct UpdateView: View {
    @Bindable var model: UpdateModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            notesSection
            Divider().opacity(0.6)
            footer
        }
        .frame(width: 460, height: 560)
        .background(.background)
    }

    // App icon + headline + "new · you have current".
    private var header: some View {
        VStack(spacing: 9) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
            Text("Update Available")
                .font(.title2).fontWeight(.semibold)
            Text("Skelf \(model.newVersion)  ·  you have \(model.currentVersion)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .padding(.bottom, 18)
    }

    // "WHAT'S NEW" + the release notes, rendered with the app's GitHub-markdown styling.
    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("WHAT’S NEW")
                .font(.caption2).fontWeight(.semibold)
                .tracking(0.7)
                .foregroundStyle(.secondary)
            ReleaseNotesView(markdown: model.notes)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1))
                .opacity(model.phase.isInstalling ? 0.5 : 1)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // Buttons when available; progress while installing; recovery options on failure.
    @ViewBuilder private var footer: some View {
        Group {
            switch model.phase {
            case .available:
                availableButtons
            case .downloading(let p):
                progressRow(label: "Downloading…  \(Int((p * 100).rounded()))%", value: p)
            case .verifying:
                progressRow(label: "Verifying…", value: nil)
            case .installing:
                progressRow(label: "Installing…", value: nil)
            case .relaunching:
                progressRow(label: "Relaunching…", value: nil)
            case .failed(let message):
                failedRow(message)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
    }

    private var availableButtons: some View {
        HStack(spacing: 10) {
            Button("Skip This Version") { model.onSkip() }
                .buttonStyle(.link)
            Spacer()
            Button("Later") { model.onLater() }
                .controlSize(.large)
            Button("Install & Relaunch") { model.onInstall() }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func progressRow(label: String, value: Double?) -> some View {
        HStack(spacing: 12) {
            if let value {
                ProgressView(value: value)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
    }

    private func failedRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Spacer()
                Button("Open Download Page") { model.onOpenPage(); model.onLater() }
                    .controlSize(.large)
                Button("Close") { model.onLater() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Release notes (reuses the app's GitHub-markdown → NSAttributedString renderer)

private struct ReleaseNotesView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 12, height: 12)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor,
                                 .cursor: NSCursor.pointingHand]
        scroll.documentView = tv
        apply(tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let tv = scroll.documentView as? NSTextView { apply(tv) }
    }

    private func apply(_ tv: NSTextView) {
        tv.textStorage?.setAttributedString(renderGitHubMarkdown(markdown))
    }
}

// MARK: - Window controller

/// Owns the single update window and routes the updater's progress into it.
final class UpdateWindowController: NSObject, NSWindowDelegate {
    static let shared = UpdateWindowController()
    private var window: NSWindow?
    private var model: UpdateModel?

    /// Show the prompt for `newVersion`. `onInstall` kicks off the download; the controller flips
    /// the window into its downloading state and locks the close button until it's done (or fails).
    func present(currentVersion: String, newVersion: String, notes: String,
                 onInstall: @escaping () -> Void, onSkip: @escaping () -> Void,
                 onOpenPage: @escaping () -> Void) {
        if window != nil { dismiss() }

        let m = UpdateModel(currentVersion: currentVersion, newVersion: newVersion, notes: notes)
        m.onInstall = { [weak self] in
            self?.model?.phase = .downloading(0)
            self?.window?.standardWindowButton(.closeButton)?.isEnabled = false
            onInstall()
        }
        m.onSkip = { [weak self] in onSkip(); self?.dismiss() }
        m.onLater = { [weak self] in self?.dismiss() }
        m.onOpenPage = onOpenPage
        model = m

        let host = NSHostingController(rootView: UpdateView(model: m))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Software Update"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(NSSize(width: 460, height: 560))
        window = w
        w.centerInScreen()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Drive the in-window progress from the updater (always called on the main thread).
    func phase(_ p: UpdateModel.Phase) {
        model?.phase = p
        if case .failed = p { window?.standardWindowButton(.closeButton)?.isEnabled = true }
    }

    func dismiss() {
        window?.delegate = nil
        window?.close()
        window = nil
        model = nil
    }

    // Clicking the red close button (allowed only when not mid-install) dismisses the prompt.
    func windowWillClose(_ notification: Notification) {
        window = nil
        model = nil
    }
}
