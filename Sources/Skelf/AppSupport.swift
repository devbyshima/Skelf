// Shared foundations: palette, gradient/flip views, animation helpers, sounds, appearance, global hot-key, AppSettings, glass card.

import AppKit
import SwiftUI
import Observation
import QuartzCore
import CoreServices
import ServiceManagement
import Carbon.HIToolbox

enum GridEntry {
    case folder(FolderStore.Node)
    case skill(Skill)
    case favorites(Int)   // the virtual Favorites folder, carrying its skill count
}

// MARK: - Shared helpers

enum Palette {
    static func hue(_ s: String) -> CGFloat {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) ^ UInt64(b) }
        return CGFloat(h % 360) / 360.0
    }
    static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == "_" })
        let letters = parts.prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
        return letters.isEmpty ? String(name.prefix(1)).uppercased() : letters
    }
    static func gradientColors(_ name: String) -> [CGColor] {
        let h = hue(name)
        return [NSColor(hue: h, saturation: 0.60, brightness: 0.96, alpha: 1).cgColor,
                NSColor(hue: fmod(h + 0.09, 1.0), saturation: 0.72, brightness: 0.76, alpha: 1).cgColor]
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

// A view whose single gradient sublayer always tracks its bounds (monogram tile).
final class GradientView: NSView {
    let gradient = CAGradientLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        layer?.addSublayer(gradient)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); gradient.frame = bounds }
}

// Scale a layer's `transform` around its own centre — avoids anchorPoint juggling
// inside Auto Layout (settles back to identity, so layout isn't disturbed).
func centerScale(_ layer: CALayer, _ s: CGFloat) -> CATransform3D {
    let w = layer.bounds.width, h = layer.bounds.height
    var t = CATransform3DIdentity
    t = CATransform3DTranslate(t, w / 2, h / 2, 0)
    t = CATransform3DScale(t, s, s, 1)
    t = CATransform3DTranslate(t, -w / 2, -h / 2, 0)
    return t
}

// A springy "pop" — squash to `from`, then overshoot back to rest (12-principles squash & stretch).
func springPop(_ layer: CALayer?, from: CGFloat = 0.9, damping: CGFloat = 11, stiffness: CGFloat = 320, mass: CGFloat = 0.85) {
    guard let layer = layer, layer.bounds.width > 1, !AppSettings.shared.reduceMotion else { return }
    let a = CASpringAnimation(keyPath: "transform")
    a.fromValue = centerScale(layer, from)
    a.toValue = CATransform3DIdentity
    a.damping = damping
    a.stiffness = stiffness
    a.mass = mass
    a.duration = a.settlingDuration
    layer.add(a, forKey: "pop")
}

// Subtle UI sounds, gated behind a setting (off by default). Uses built-in system sounds.
enum Sound {
    static var enabled = UserDefaults.standard.bool(forKey: "soundEnabled")   // default false
    private static var cache: [String: NSSound] = [:]

    static func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "soundEnabled")
        if on { play(.copy) }   // a preview when you switch it on
    }

    enum Cue: String { case copy = "Tink", move = "Pop" }

    static func play(_ cue: Cue, volume: Float = 0.4) {
        guard enabled else { return }
        let s = cache[cue.rawValue] ?? NSSound(named: NSSound.Name(cue.rawValue))
        cache[cue.rawValue] = s
        s?.volume = volume
        if s?.isPlaying == true { s?.stop() }
        s?.currentTime = 0
        s?.play()
    }
}

// The app's appearance override (a standard macOS preference). System defers to the OS.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "Follow System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

// A system-wide hot-key to toggle the menu-bar popover, via Carbon's RegisterEventHotKey —
// the one API that works from the background without Accessibility permissions. The default
// chord is ⌥⌘S; `onFire` is wired once by the AppDelegate and runs on the main thread.
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    static let defaultKeyCode = UInt32(kVK_ANSI_S)
    static let defaultModifiers = UInt32(cmdKey | optionKey)
    static let displayString = "⌥⌘S"

    var onFire: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let signature: OSType = 0x534B_4C46            // 'SKLF'

    var isRegistered: Bool { ref != nil }

    func register(keyCode: UInt32 = GlobalHotKey.defaultKeyCode, modifiers: UInt32 = GlobalHotKey.defaultModifiers) {
        unregister()
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
                guard let userData = userData else { return noErr }
                Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().onFire?()
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
    }
}

// App-wide preferences shown in the Settings window. Each toggle persists to UserDefaults
// and applies its side effect immediately.
@Observable
final class AppSettings {
    static let shared = AppSettings()
    private enum Keys {
        static let menuBarOnly = "menuBarOnly", reduceMotion = "reduceMotion", usePaintings = "usePaintings"
        static let appearance = "appearance", globalHotKey = "globalHotKeyEnabled"
        static let autoCheckUpdates = "autoCheckUpdates"
        static let aiFeatures = "aiFeaturesEnabled"
    }

    private var applyingLogin = false
    /// Open at login via the modern ServiceManagement API (macOS 13+).
    var launchAtLogin: Bool {
        didSet {
            guard !applyingLogin, launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                applyingLogin = true                       // system rejected it → reflect real state
                launchAtLogin = (SMAppService.mainApp.status == .enabled)
                applyingLogin = false
            }
        }
    }
    /// Run from the menu bar with no Dock icon (activation policy .accessory).
    var menuBarOnly: Bool {
        didSet { UserDefaults.standard.set(menuBarOnly, forKey: Keys.menuBarOnly); applyMenuBarOnly() }
    }
    var playSounds: Bool { didSet { if playSounds != Sound.enabled { Sound.setEnabled(playSounds) } } }
    /// Honor reduced-motion: skip the spring/pop animations.
    var reduceMotion: Bool { didSet { UserDefaults.standard.set(reduceMotion, forKey: Keys.reduceMotion) } }
    /// Show museum paintings on cards (off → the generated themed art only, fully offline).
    var usePaintings: Bool {
        didSet {
            UserDefaults.standard.set(usePaintings, forKey: Keys.usePaintings)
            NotificationCenter.default.post(name: AppSettings.artChanged, object: nil)
        }
    }
    /// Light / Dark / Follow System override for the whole app.
    var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance); applyAppearance() }
    }
    /// Toggle the menu-bar popover from anywhere with ⌥⌘S.
    var globalHotKey: Bool {
        didSet { UserDefaults.standard.set(globalHotKey, forKey: Keys.globalHotKey); applyHotKey() }
    }
    /// Check GitHub for a newer Skelf on launch and once a day (see Updater).
    var autoCheckUpdates: Bool {
        didSet { UserDefaults.standard.set(autoCheckUpdates, forKey: Keys.autoCheckUpdates) }
    }
    /// Use Apple's on-device model (Foundation Models) for natural-language skill search and
    /// plain-English summaries. Honored only on capable hardware; see SkillFinder.isAvailable.
    var useAIFeatures: Bool {
        didSet { UserDefaults.standard.set(useAIFeatures, forKey: Keys.aiFeatures) }
    }
    static let artChanged = Notification.Name("SkelfArtSettingChanged")

    private init() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        menuBarOnly = UserDefaults.standard.bool(forKey: Keys.menuBarOnly)
        playSounds = Sound.enabled
        reduceMotion = UserDefaults.standard.bool(forKey: Keys.reduceMotion)
        usePaintings = (UserDefaults.standard.object(forKey: Keys.usePaintings) as? Bool) ?? true
        appearance = AppAppearance(rawValue: UserDefaults.standard.string(forKey: Keys.appearance) ?? "") ?? .system
        globalHotKey = (UserDefaults.standard.object(forKey: Keys.globalHotKey) as? Bool) ?? true
        autoCheckUpdates = (UserDefaults.standard.object(forKey: Keys.autoCheckUpdates) as? Bool) ?? true
        useAIFeatures = (UserDefaults.standard.object(forKey: Keys.aiFeatures) as? Bool) ?? true
    }

    func applyMenuBarOnly() {
        NSApp.setActivationPolicy(menuBarOnly ? .accessory : .regular)
        if !menuBarOnly { NSApp.activate(ignoringOtherApps: true) }
    }
    func applyAppearance() { NSApp.appearance = appearance.nsAppearance }
    func applyHotKey() {
        if globalHotKey { GlobalHotKey.shared.register() } else { GlobalHotKey.shared.unregister() }
    }
    /// Apply persisted policy + appearance once at launch (before the UI shows).
    func applyOnLaunch() {
        if menuBarOnly { NSApp.setActivationPolicy(.accessory) }
        applyAppearance()
    }
}

// A Liquid Glass card. On macOS 27 this gains corners concentric with its container
// (NSViewCornerConfiguration / .containerConcentric), but that refinement is deferred until the
// macOS 27 SDK is the released toolchain — so for now it's a plain glass card and callers set
// cornerRadius. Re-add the `cornerConfiguration` override here when building on Xcode 27+.
final class GlassCardView: NSGlassEffectView {}

// Verifies that a skill's actual GitHub page exists (HEAD the skill's /tree/HEAD/<path>
// URL — which also proves the repo and owner exist). Only skills whose page is confirmed
// may be auto-filed under a creator; otherwise we can't say who the skill belongs to, so
// it stays unfiled. Confirmed URLs persist (UserDefaults); 404s/errors stay in memory so
// a renamed path or flaky network can re-resolve on a future launch. Checks are capped at
// a few concurrent requests so a large library doesn't hammer GitHub.
