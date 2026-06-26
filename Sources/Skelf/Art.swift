// GitHub page verification, creator-avatar + public-domain painting fetching and caching, and art theming helpers.

import AppKit
import SwiftUI
import Observation
import QuartzCore
import CoreServices
import ServiceManagement
import Carbon.HIToolbox

final class GitHubVerifier {
    static let shared = GitHubVerifier()
    private let key = "verifiedPagesV1"
    private var verified: Set<String>
    private var notFound: Set<String> = []
    private var inflight: Set<String> = []

    init() { verified = Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }

    /// true = page exists, false = confirmed missing (404), nil = not checked yet.
    func status(_ urlString: String) -> Bool? {
        if verified.contains(urlString) { return true }
        if notFound.contains(urlString) { return false }
        return nil
    }

    /// HEAD-check the URL; calls back on the main queue once resolved (or immediately if
    /// already known). Connection-level throttling is handled by URLSession's
    /// httpMaximumConnectionsPerHost (default 6). Must be called on the main queue.
    func verify(_ urlString: String, completion: @escaping () -> Void) {
        if status(urlString) != nil || inflight.contains(urlString) { completion(); return }
        start(urlString, completion)
    }

    private func start(_ s: String, _ completion: @escaping () -> Void) {
        guard let url = URL(string: s) else { notFound.insert(s); completion(); return }
        inflight.insert(s)
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.inflight.remove(s)
                if let code = (resp as? HTTPURLResponse)?.statusCode {
                    if code == 200 {
                        self.verified.insert(s)
                        UserDefaults.standard.set(Array(self.verified), forKey: self.key)
                    } else if code == 404 || code == 451 {
                        self.notFound.insert(s)
                    }   // rate-limit / 5xx / transient: leave unknown, retry next launch
                }
                completion()
            }
        }.resume()
    }
}

// MARK: - Grid tile

// Fetches + disk-caches a creator's public GitHub avatar (no token needed:
// https://github.com/<user>.png). Memory + on-disk cache keep scrolling cheap.
final class AvatarStore {
    static let shared = AvatarStore()
    private var mem: [String: NSImage] = [:]
    private var failed: Set<String> = []
    private var inflight: Set<String> = []
    private let dir: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        dir = base.appendingPathComponent("dev.fulltime.skelf/avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func diskURL(_ creator: String) -> URL {
        dir.appendingPathComponent(creator.replacingOccurrences(of: "/", with: "_") + ".png")
    }

    /// Synchronous cache hit (memory, then disk); nil if not fetched yet.
    func cached(_ creator: String) -> NSImage? {
        if let i = mem[creator] { return i }
        if let i = NSImage(contentsOf: diskURL(creator)) { mem[creator] = i; return i }
        return nil
    }

    /// Fetch if needed; calls back on the main queue with the avatar (or nil). Must be called on main.
    func fetch(_ creator: String, completion: @escaping (NSImage?) -> Void) {
        if let i = cached(creator) { completion(i); return }
        if failed.contains(creator) { completion(nil); return }
        if inflight.contains(creator) { return }   // a fetch is already running
        guard let url = URL(string: "https://github.com/\(creator).png?size=400") else { completion(nil); return }
        inflight.insert(creator)
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.inflight.remove(creator)
                if let data = data, let img = NSImage(data: data) {
                    try? data.write(to: self.diskURL(creator))
                    self.mem[creator] = img
                    completion(img)
                } else {
                    self.failed.insert(creator)
                    completion(nil)
                }
            }
        }.resume()
    }
}

// Per-skill card art: a stunning NASA public-domain space image, drawn from a bundled pool
// (`art-map.json` = a list of image URLs) and assigned to each skill by a stable hash with
// linear-probe dedup, so every skill — present or future, for any user — gets its own
// distinct image. Downloads are disk-cached like avatars. With covers off (or on a fetch
// failure) a skill falls back to a GENERATED themed image (gradient + purpose-matched icon).
// Folders keep their creator avatar (AvatarStore); only skill cards use this.
final class ArtStore {
    static let shared = ArtStore()
    private var pool: [String] = []                            // bundled NASA image URLs (art-map.json)
    private var assignment: [String: Int] = [:]                // skill id → pool index (deduped)
    private var mem: [String: NSImage] = [:]
    private var failed: Set<String> = []
    private var inflight: Set<String> = []
    private var waiters: [String: [(NSImage) -> Void]] = [:]   // cards awaiting an in-flight download
    // Bump when the art SOURCE changes so stale on-disk caches are wiped once on upgrade.
    private static let cacheVersion = 5
    private static let cacheVersionKey = "artCacheVersion"
    private let dir: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        dir = base.appendingPathComponent("dev.fulltime.skelf/art", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // One-time wipe of art cached under an older source (old paintings → modern/digital art).
        if UserDefaults.standard.integer(forKey: Self.cacheVersionKey) != Self.cacheVersion {
            if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for f in files { try? FileManager.default.removeItem(at: f) }
            }
            UserDefaults.standard.set(Self.cacheVersion, forKey: Self.cacheVersionKey)
        }
        if let u = skelfResourceBundle.url(forResource: "art-map", withExtension: "json"),
           let d = try? Data(contentsOf: u),
           let arr = try? JSONDecoder().decode([String].self, from: d) {
            pool = arr
        }
    }

    /// Assign a distinct pool image to each installed skill (stable hash + linear-probe dedup),
    /// so a library never repeats an image. Call on load and whenever the skill set changes.
    func updateAssignment(_ ids: [String]) {
        guard !pool.isEmpty else { return }
        var used = Set<Int>(); var map: [String: Int] = [:]
        for id in ids.sorted() {
            var slot = Self.stableIndex(id, pool.count), tries = 0
            while used.contains(slot) && tries < pool.count { slot = (slot + 1) % pool.count; tries += 1 }
            used.insert(slot); map[id] = slot
        }
        assignment = map
    }

    private func poolURL(for id: String) -> String? {
        guard !pool.isEmpty else { return nil }
        return pool[assignment[id] ?? Self.stableIndex(id, pool.count)]
    }

    private static func stableIndex(_ s: String, _ n: Int) -> Int {
        var h: UInt64 = 5381; for b in s.utf8 { h = (h &* 33) ^ UInt64(b) }
        return n > 0 ? Int(h % UInt64(n)) : 0
    }

    /// Forget every downloaded image (memory + disk) so the next view re-fetches it.
    func clearCache() {
        mem.removeAll(); failed.removeAll(); inflight.removeAll(); waiters.removeAll()
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
    }

    private func diskURL(_ id: String) -> URL {
        dir.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".img")
    }

    /// Synchronous cache hit for already-downloaded CC art; nil if not (yet) available or if
    /// the user turned painting covers off (then cards use the generated art).
    func cached(_ id: String) -> NSImage? {
        guard AppSettings.shared.usePaintings else { return nil }
        if let i = mem[id] { return i }
        if let i = NSImage(contentsOf: diskURL(id)) { mem[id] = i; return i }
        return nil
    }

    /// Resolve + download the skill's assigned NASA image; calls back on main with the image
    /// (or nil — caller keeps the generated themed fallback). Call on main.
    func fetch(_ skill: Skill, completion: @escaping (NSImage?) -> Void) {
        guard AppSettings.shared.usePaintings else { completion(nil); return }   // generated art only
        let id = skill.id
        if let i = cached(id) { completion(i); return }
        if failed.contains(id) { completion(nil); return }
        guard let urlStr = poolURL(for: id) else { completion(nil); return }
        // Queue this card's callback — every card awaiting the same in-flight image is
        // notified when it lands (NSCollectionView recycles cells, so the card that started
        // the download is often gone by the time it finishes).
        waiters[id, default: []].append { completion($0) }
        if inflight.contains(id) { return }
        inflight.insert(id)
        download(Self.sizedURLs(urlStr), 0) { [weak self] img, data in
            guard let self = self else { return }
            if let img = img, let data = data { try? data.write(to: self.diskURL(id)); self.mem[id] = img }
            self.inflight.remove(id)
            let cbs = self.waiters.removeValue(forKey: id) ?? []
            if let img = img { cbs.forEach { $0(img) } } else { self.failed.insert(id) }
        }
    }

    // NASA asset sizes: try large → medium → small → orig → the stored URL, so a missing size
    // still resolves to a real raster image.
    private static func sizedURLs(_ url: String) -> [String] {
        guard let tilde = url.range(of: "~", options: .backwards) else { return [url] }
        let base = String(url[..<tilde.lowerBound])
        return [base + "~large.jpg", base + "~medium.jpg", base + "~small.jpg", base + "~orig.jpg", url]
    }

    private func download(_ urls: [String], _ i: Int, _ done: @escaping (NSImage?, Data?) -> Void) {
        guard i < urls.count, let url = URL(string: urls[i]) else { done(nil, nil); return }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Skelf/\(skelfShortVersion) (https://github.com/devbyshima/Skelf)", forHTTPHeaderField: "User-Agent")
        // The completion runs on a background queue — decode there (NASA images can be large;
        // skip multi-hundred-MB masters) and hop to main only with the finished image.
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            if ok, let data = data, data.count < 12_000_000, let img = NSImage(data: data), img.size.width > 1 {
                DispatchQueue.main.async { done(img, data) }
            } else {
                DispatchQueue.main.async { self?.download(urls, i + 1, done) }
            }
        }.resume()
    }
}

// Pick a purpose-matched SF Symbol for a skill's generated fallback art, by scanning its
// name/category/description for evocative keywords.
func artSymbol(for skill: Skill) -> String {
    let hay = (skill.name + " " + skill.category + " " + skill.description).lowercased()
    let table: [(String, String)] = [
        ("animation", "play.circle"), ("animate", "play.circle"), ("motion", "wind"), ("spring", "wind"),
        ("sound", "waveform"), ("audio", "waveform"), ("voice", "waveform"),
        ("icon", "square.grid.2x2"), ("morph", "square.on.square.dashed"),
        ("test", "checkmark.seal"), ("tdd", "checkmark.seal"), ("qa", "checkmark.seal"),
        ("bug", "ladybug"), ("diagnos", "stethoscope"), ("debug", "ladybug"),
        ("refactor", "wand.and.stars"), ("architecture", "building.columns"), ("scaffold", "square.stack.3d.up"),
        ("design", "paintbrush"), ("interface", "rectangle.3.group"), ("ui", "rectangle.3.group"),
        ("prototype", "scribble.variable"), ("sketch", "scribble.variable"),
        ("domain", "cube"), ("model", "cube"), ("language", "character.bubble"),
        ("prd", "doc.text"), ("article", "doc.richtext"), ("writing", "pencil.line"), ("write", "pencil.line"),
        ("issue", "tray.full"), ("triage", "tray.and.arrow.down"), ("handoff", "arrow.left.arrow.right"),
        ("git", "arrow.triangle.branch"), ("merge", "arrow.triangle.merge"), ("commit", "arrow.triangle.branch"),
        ("review", "checklist"), ("decision", "signpost.right"), ("map", "map"),
        ("teach", "graduationcap"), ("grill", "flame"), ("ask", "bubble.left.and.bubble.right"),
        ("interview", "bubble.left.and.bubble.right"), ("docs", "books.vertical"),
        ("obsidian", "square.stack"), ("vault", "lock.square"), ("market", "megaphone"),
        ("human", "person.and.background.dotted"), ("caveman", "figure.walk"), ("zoom", "magnifyingglass"),
        ("pre-commit", "checkmark.shield"), ("guardrail", "shield.lefthalf.filled"),
        ("shoehorn", "shippingbox"), ("migrate", "arrow.up.forward.square"),
        ("principle", "list.number"), ("fragment", "puzzlepiece"), ("shape", "scribble"),
        ("beat", "metronome"), ("ubiquitous", "character.bubble"), ("exercise", "figure.run")
    ]
    for (kw, sym) in table where hay.contains(kw) { return sym }
    // category-based default, else a generic spark
    switch skill.category.lowercased() {
    case "engineering": return "hammer"
    case "productivity": return "bolt"
    case "in-progress": return "hourglass"
    case "deprecated": return "archivebox"
    default: return "sparkles"
    }
}

