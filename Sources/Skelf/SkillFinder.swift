// On-device skill intelligence powered by Apple's Foundation Models (the ~3B model behind
// Apple Intelligence). Two features live here:
//
//   • a natural-language "which skill do I need?" finder — the user types a task in their
//     own words ("my emails keep landing in spam") and the model ranks the installed skills
//     that actually fit, where today's literal substring search would return nothing;
//   • per-skill plain-English summaries shown in the detail SUMMARY card.
//
// Everything is BEST-EFFORT and PURELY ADDITIVE. The on-device model is only usable on
// Apple-Intelligence-capable hardware with the feature enabled and assets downloaded, so
// every entry point first checks `isAvailable`; when it's false (Intel Mac, Apple
// Intelligence off, still downloading, or the user turned it off in Settings) callers fall
// back to the existing substring search / raw description — no error, spinner, or nag.
//
// The deployment target is macOS 26 (Package.swift / build.sh / Info.plist), which is the
// floor for FoundationModels, so the framework is unconditionally available — no @available.

import Foundation
import FoundationModels

@MainActor
final class SkillFinder {
    static let shared = SkillFinder()
    private init() {}

    private let model = SystemLanguageModel.default

    // Tuning. A token is ~3–4 chars and a session shares a 4,096-token budget across
    // instructions + prompt + output, so the catalog we hand the model is pre-filtered to a
    // bounded shortlist of short lines — input scales with `candidateLimit`, not library size.
    private static let candidateLimit = 50      // max skills sent to the model per query
    private static let descLimit = 140          // chars of each skill's description we include

    // Caches so re-running the same query / re-opening the same skill is instant and free.
    private var rankCache: [String: [String]] = [:]
    private var summaryCache: [String: SkillSummary] = [:]
    private var summaryTasks: [String: Task<SkillSummary?, Never>] = [:]
    private var prewarmSession: LanguageModelSession?

    /// True only when the on-device model can actually run a request right now AND the user
    /// hasn't switched the feature off. Every caller gates on this before doing AI work.
    var isAvailable: Bool {
        guard AppSettings.shared.useAIFeatures else { return false }
        guard case .available = model.availability else { return false }
        return model.supportsLocale(.current)
    }

    /// Warm the model runtime so the first real query is snappy. Cheap no-op when unavailable
    /// or already warmed; called when a search field gains focus.
    func prewarm() {
        guard isAvailable, prewarmSession == nil else { return }
        let session = makeFinderSession()
        session.prewarm()
        prewarmSession = session
    }

    // MARK: - Natural-language finder

    @Generable
    struct SkillMatchResult {
        @Guide(description: "Skill ids copied EXACTLY from the catalog, most relevant first. Include only skills that genuinely fit the task; omit the rest.", .maximumCount(8))
        var ids: [String]
    }

    /// Rank installed skills against a natural-language task. Returns skill ids best-first,
    /// or nil when the model is unavailable, the query is trivial, or anything throws — in
    /// every nil case the caller simply keeps its existing substring results.
    func rank(query: String, candidates: [Skill]) async -> [String]? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAvailable, q.count >= 3, !candidates.isEmpty else { return nil }
        let key = q.lowercased()
        if let cached = rankCache[key] { return cached }

        let shortlist = Self.prefilter(query: q, skills: candidates, limit: Self.candidateLimit)
        let valid = Set(shortlist.map { $0.id })
        let catalog = shortlist
            .map { "\($0.id) | \($0.name) | \(Self.shortDesc($0.description))" }
            .joined(separator: "\n")
        let prompt = "Task: \(q)\n\nCatalog (one skill per line, `id | name | summary`):\n\(catalog)"

        do {
            let session = makeFinderSession()
            let response = try await session.respond(
                to: prompt,
                generating: SkillMatchResult.self,
                options: GenerationOptions(temperature: 0, maximumResponseTokens: 200)
            )
            // Defensively drop any id the model invented; preserve its ranking order.
            let ranked = response.content.ids.filter { valid.contains($0) }
            guard !ranked.isEmpty else { return nil }
            rankCache[key] = ranked
            return ranked
        } catch {
            return nil
        }
    }

    private func makeFinderSession() -> LanguageModelSession {
        // Fresh session per query: each rank is independent, so we never accumulate a
        // transcript that would eat into the context window. Instructions are
        // developer-authored only — the user's query goes in the prompt (injection-safe).
        LanguageModelSession {
            """
            You match a developer's task to the right tool from a fixed catalog of "skills".
            You receive the task and a catalog where each line is `id | name | summary`.
            Return the ids — copied EXACTLY from the catalog — of the skills that best
            accomplish the task, most relevant first, at most 8, omitting any that don't
            clearly fit. The catalog is the ONLY source of truth: never invent an id that is
            not present, and don't rely on outside knowledge of tools.
            """
        }
    }

    // MARK: - Per-skill summary

    @Generable
    struct SkillSummary: Equatable {
        @Guide(description: "One plain, jargon-light sentence on what this skill does.")
        var whatItDoes: String
        @Guide(description: "The situation it's best for, as a short lowercase phrase — e.g. \"reviewing SwiftUI code\" or \"debugging shader performance\". Not a full sentence; do not start with \"When\".")
        var whenToUse: String
    }

    /// A plain-English summary of a skill, generated once and cached. Returns nil when the
    /// model is unavailable or generation fails (the detail view then shows just the raw
    /// description, as before). Coalesces concurrent requests for the same skill.
    func summary(for skill: Skill) async -> SkillSummary? {
        guard isAvailable else { return nil }
        if let cached = summaryCache[skill.id] { return cached }
        if let inflight = summaryTasks[skill.id] { return await inflight.value }

        let task = Task { () -> SkillSummary? in
            let desc = skill.description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !desc.isEmpty else { return nil }
            let prompt = "Skill name: \(skill.name)\nRaw description: \(Self.cap(desc, 600))"
            do {
                let session = LanguageModelSession {
                    """
                    You explain developer tools plainly. Given a tool's name and its raw
                    description, write a crisp, concrete explanation in everyday language.
                    Keep each field to one sentence and don't invent capabilities the
                    description doesn't mention.
                    """
                }
                let response = try await session.respond(
                    to: prompt,
                    generating: SkillSummary.self,
                    options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 160)
                )
                return response.content
            } catch {
                return nil
            }
        }
        summaryTasks[skill.id] = task
        let result = await task.value
        summaryTasks[skill.id] = nil
        if let result = result { summaryCache[skill.id] = result }
        return result
    }

    // MARK: - Helpers

    /// Collapse + truncate a description to a short single line for the catalog.
    private static func shortDesc(_ d: String) -> String {
        let collapsed = d.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return cap(collapsed, descLimit)
    }

    private static func cap(_ s: String, _ n: Int) -> String {
        guard s.count > n else { return s }
        return String(s.prefix(n)) + "…"
    }

    private static func tokenize(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 }
    }

    /// Lexical top-K pre-filter: rank by query/skill word overlap, then pad with the rest so
    /// the model still has candidates when overlap is poor. Caps prompt size for big libraries.
    private static func prefilter(query: String, skills: [Skill], limit: Int) -> [Skill] {
        guard skills.count > limit else { return skills }
        let qWords = Set(tokenize(query))
        func score(_ s: Skill) -> Int {
            let hay = Set(tokenize(s.name + " " + s.description + " " + s.category))
            return qWords.reduce(0) { $0 + (hay.contains($1) ? 1 : 0) }
        }
        let overlapping = skills.map { ($0, score($0)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
        if overlapping.count >= limit { return Array(overlapping.prefix(limit)) }
        let chosen = Set(overlapping.map { $0.id })
        let rest = skills.filter { !chosen.contains($0.id) }
        return Array((overlapping + rest).prefix(limit))
    }
}
