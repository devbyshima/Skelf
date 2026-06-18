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
    private var queued: [(String, () -> Void)] = []
    private let maxInflight = 5

    init() { verified = Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }

    /// true = page exists, false = confirmed missing (404), nil = not checked yet.
    func status(_ urlString: String) -> Bool? {
        if verified.contains(urlString) { return true }
        if notFound.contains(urlString) { return false }
        return nil
    }

    /// HEAD-check the URL (throttled); calls back on the main queue once resolved (or
    /// immediately if already known). Must be called on the main queue.
    func verify(_ urlString: String, completion: @escaping () -> Void) {
        if status(urlString) != nil { completion(); return }
        queued.append((urlString, completion))
        pump()
    }

    private func pump() {
        while inflight.count < maxInflight, !queued.isEmpty {
            let (s, done) = queued.removeFirst()
            if status(s) != nil || inflight.contains(s) { done(); continue }
            start(s, done)
        }
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
                self.pump()
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

// Per-skill card art: a UNIQUE, publicly-available (Creative-Commons) image themed to
// each skill, sourced from a bundled `art-map.json` (skill id → CC image URL, deduped so
// no two skills share art). Downloads are disk-cached like avatars. A skill with no map
// entry (or offline) falls back to a GENERATED themed image (unique gradient + a
// purpose-matched icon) — so every skill always has its own distinct art. Folders keep
// their creator avatar (AvatarStore); only skill cards use this.
final class ArtStore {
    static let shared = ArtStore()
    struct Entry: Decodable {
        let url: String
        let title: String?; let artist: String?; let date: String?; let why: String?
        let medium: String?; let origin: String?; let dimensions: String?; let description: String?
        let by: String?; let license: String?
    }
    // What the banner popover shows about a skill's painting.
    struct Details {
        let title: String; let artist: String; let date: String
        let medium: String; let origin: String; let dimensions: String; let description: String
        let why: String; let license: String
    }
    private var map: [String: Entry] = [:]
    private var mem: [String: NSImage] = [:]
    private var failed: Set<String> = []
    private var inflight: Set<String> = []
    private var waiters: [String: [(NSImage) -> Void]] = [:]   // cards awaiting an in-flight download
    private var usedImages: Set<String> = []                   // AIC image ids already taken (dedup)
    private var runtimeAttribution: [String: String] = [:]     // skill id → "Title — Artist" for runtime picks
    private var runtimeWhy: [String: String] = [:]             // skill id → why-this-painting (runtime)
    private let dir: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        dir = base.appendingPathComponent("dev.fulltime.skelf/art", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let u = skelfResourceBundle.url(forResource: "art-map", withExtension: "json"),
           let d = try? Data(contentsOf: u),
           let m = try? JSONDecoder().decode([String: Entry].self, from: d) {
            map = m
        }
        // Seed the dedup set with every image already claimed by the curated map, so a
        // runtime-resolved skill never reuses a curated painting.
        for e in map.values { if let iid = Self.aicImageId(e.url) { usedImages.insert(iid) } }
    }

    /// Forget every downloaded painting (memory + disk) so the next view re-fetches it.
    /// Runtime picks reset too; the curated dedup seed is rebuilt from the bundled map.
    func clearCache() {
        mem.removeAll(); failed.removeAll(); inflight.removeAll(); waiters.removeAll()
        runtimeAttribution.removeAll(); runtimeWhy.removeAll()
        usedImages.removeAll()
        for e in map.values { if let iid = Self.aicImageId(e.url) { usedImages.insert(iid) } }
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
    }

    private static func aicImageId(_ url: String) -> String? {
        // …/iiif/2/<image_id>/full/…
        guard let r = url.range(of: "/iiif/2/") else { return nil }
        return url[r.upperBound...].split(separator: "/").first.map(String.init)
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

    func hasArt(_ id: String) -> Bool { map[id] != nil }

    // Painting details for the banner popover (curated map, else a runtime pick).
    func details(_ id: String) -> Details? {
        if let e = map[id] {
            return Details(title: e.title ?? e.by ?? "Untitled", artist: e.artist ?? "Unknown", date: e.date ?? "",
                           medium: e.medium ?? "", origin: e.origin ?? "", dimensions: e.dimensions ?? "",
                           description: e.description ?? "", why: e.why ?? "",
                           license: e.license ?? "Public domain · Art Institute of Chicago")
        }
        if let by = runtimeAttribution[id] {
            let parts = by.components(separatedBy: " — ")
            return Details(title: parts.first ?? by, artist: parts.count > 1 ? parts[1] : "Unknown", date: "",
                           medium: "", origin: "", dimensions: "", description: "", why: runtimeWhy[id] ?? "",
                           license: "Public domain · Art Institute of Chicago")
        }
        return nil
    }

    /// Resolve and download a painting for `skill`; calls back on main with the image (or nil
    /// if it can't find one / fails — the caller keeps the themed fallback). For a skill in the
    /// bundled curated map it uses that painting; otherwise it searches the Art Institute live
    /// so ANY user's skills get a relevant painting with no setup. Call on main.
    func fetch(_ skill: Skill, completion: @escaping (NSImage?) -> Void) {
        guard AppSettings.shared.usePaintings else { completion(nil); return }   // generated art only
        let id = skill.id
        if let i = cached(id) { completion(i); return }
        if failed.contains(id) { completion(nil); return }
        // Queue this card's callback — every card awaiting the same in-flight image is
        // notified when it lands (NSCollectionView recycles cells, so the card that started
        // the download is often gone by the time it finishes).
        waiters[id, default: []].append { completion($0) }
        if inflight.contains(id) { return }
        inflight.insert(id)
        resolveURL(skill) { [weak self] url in
            guard let self = self else { return }
            guard let url = url else { self.deliver(id, nil); return }
            var req = URLRequest(url: url)
            req.setValue("Skelf/\(skelfShortVersion) (skill art)", forHTTPHeaderField: "User-Agent")
            // The Art Institute of Chicago's IIIF image server requires this header (else 403).
            req.setValue("Skelf (https://github.com/devbyshima/Skelf)", forHTTPHeaderField: "AIC-User-Agent")
            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if let data = data, let img = NSImage(data: data) {
                        try? data.write(to: self.diskURL(id)); self.mem[id] = img; self.deliver(id, img)
                    } else { self.deliver(id, nil) }
                }
            }.resume()
        }
    }

    private func deliver(_ id: String, _ img: NSImage?) {
        inflight.remove(id)
        let cbs = waiters.removeValue(forKey: id) ?? []
        if let img = img { cbs.forEach { $0(img) } } else { failed.insert(id) }
    }

    // Curated map for known skills, else a live Art Institute search for this skill's theme.
    private func resolveURL(_ skill: Skill, _ done: @escaping (URL?) -> Void) {
        if let entry = map[skill.id], let url = URL(string: entry.url) { done(url); return }
        runtimeSearch(skill, done)
    }

    private func runtimeSearch(_ skill: Skill, _ done: @escaping (URL?) -> Void) {
        var comp = URLComponents(string: "https://api.artic.edu/api/v1/artworks/search")!
        comp.queryItems = [
            .init(name: "q", value: artKeyword(for: skill)),
            .init(name: "query[term][is_public_domain]", value: "true"),
            .init(name: "fields", value: "image_id,title,artist_title,classification_titles"),
            .init(name: "limit", value: "40")]
        guard let url = comp.url else { done(nil); return }
        var req = URLRequest(url: url)
        req.setValue("Skelf (https://github.com/devbyshima/Skelf)", forHTTPHeaderField: "AIC-User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self else { return }
            var pick: (id: String, title: String, artist: String)?
            if let data = data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = obj["data"] as? [[String: Any]] {
                func scan(paintingsOnly: Bool) {
                    for r in results where pick == nil {
                        guard let iid = r["image_id"] as? String, !iid.isEmpty,
                              !self.usedImages.contains(iid) else { continue }
                        let cls = (r["classification_titles"] as? [String])?.map { $0.lowercased() } ?? []
                        if paintingsOnly && !cls.contains(where: { $0.contains("painting") }) { continue }
                        pick = (iid, r["title"] as? String ?? "Untitled", r["artist_title"] as? String ?? "Unknown")
                    }
                }
                scan(paintingsOnly: true)
                if pick == nil { scan(paintingsOnly: false) }   // accept any artwork if no painting
            }
            let kw = artKeyword(for: skill)
            DispatchQueue.main.async {
                guard let p = pick else { done(nil); return }
                self.usedImages.insert(p.id)
                self.runtimeAttribution[skill.id] = "\(p.title) — \(p.artist)"
                self.runtimeWhy[skill.id] = "Chosen to match this skill — a public-domain artwork on the theme of “\(kw)”."
                done(URL(string: "https://www.artic.edu/iiif/2/\(p.id)/full/843,/0/default.jpg"))
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

// A paintable MUSEUM-SEARCH subject for a skill — used at runtime to find a relevant
// public-domain painting for skills NOT in the curated map (so any user's skills get art).
// Maps the skill's purpose to a concrete painting subject the Art Institute search will hit.
func artKeyword(for skill: Skill) -> String {
    let hay = (skill.name + " " + skill.category + " " + skill.description).lowercased()
    let table: [(String, String)] = [
        ("animation", "dancers"), ("animate", "dancers"), ("motion", "horses"), ("spring", "fountain"),
        ("sound", "musicians"), ("audio", "musicians"), ("music", "musicians"),
        ("icon", "still life"), ("morph", "metamorphosis"),
        ("test", "still life"), ("tdd", "still life"), ("qa", "inspection"),
        ("bug", "anatomy"), ("diagnos", "physician"), ("debug", "anatomy"),
        ("refactor", "scaffold"), ("architect", "architecture"), ("scaffold", "construction"),
        ("design", "sketch"), ("interface", "facade"), ("prototype", "study"), ("sketch", "drawing"),
        ("domain", "map"), ("model", "map"), ("language", "manuscript"), ("ubiquitous", "atlas"),
        ("prd", "manuscript"), ("article", "manuscript"), ("writ", "manuscript"), ("edit", "scribe"),
        ("issue", "harvest"), ("triage", "physician"), ("handoff", "relay"), ("merge", "bridge"),
        ("git", "fortress"), ("commit", "fortress"), ("guardrail", "fortress"), ("pre-commit", "gate"),
        ("review", "scholar"), ("decision", "crossroads"), ("map", "map"), ("plan", "map"),
        ("teach", "classroom"), ("grill", "interrogation"), ("ask", "conversation"),
        ("interview", "tribunal"), ("docs", "library"), ("doc", "library"),
        ("obsidian", "library"), ("vault", "library"), ("market", "market"),
        ("human", "portrait"), ("caveman", "cave"), ("zoom", "panorama"),
        ("migrate", "caravan"), ("shoehorn", "harbor"),
        ("principle", "geometry"), ("fragment", "mosaic"), ("shape", "sculptor"),
        ("beat", "orchestra"), ("exercise", "gymnasium"), ("implement", "blacksmith"),
        ("setup", "workshop"), ("config", "workshop"), ("scan", "panorama")
    ]
    for (kw, subj) in table where hay.contains(kw) { return subj }
    // Fall back to the skill's own first name word, else a safe broad subject.
    let word = skill.name.lowercased().split(whereSeparator: { "-_ ".contains($0) }).first.map(String.init) ?? ""
    return word.count >= 4 ? word : "landscape"
}

// A skill/folder "image": a single cached bitmap layer (creator avatar, or a
// pre-rendered gradient fallback) + a bottom scrim. No live gradients/text layers,
// so scrolling stays smooth.
