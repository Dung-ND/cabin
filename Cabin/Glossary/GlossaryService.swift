import Foundation

struct GlossaryCard: Identifiable, Equatable {
    let id = UUID()
    let term: String
    let definition: String
    /// "wikipedia" or "llm" (inferred from context).
    let source: String
    let url: String?
    let createdAt = Date()
    var pinned = false
}

/// Watches transcript text for uncommon terms and explains them (cached in the DB, so each term is looked up once).
@MainActor
final class GlossaryService {
    var onCard: ((GlossaryCard) -> Void)?
    var onError: ((String) -> Void)?

    private let db: AppDatabase
    private let settings: AppSettings
    private var detector: RareWordDetector?
    private var detectorKey = ""
    private var sessionId: Int64?
    private var known: Set<String> = []
    private var handledThisSession: Set<String> = []
    private var pending: [String] = []
    private var flushTask: Task<Void, Never>?
    private var context = ""

    init(db: AppDatabase, settings: AppSettings) {
        self.db = db
        self.settings = settings
    }

    func begin(sessionId: Int64) {
        self.sessionId = sessionId
        let key = "\(settings.languageCode)-\(settings.commonWordCutoff)"
        if detector == nil || detectorKey != key {
            detector = RareWordDetector.load(language: settings.language, cutoff: settings.commonWordCutoff)
            detectorKey = key
        }
        known = (try? db.knownTermNames()) ?? []
        handledThisSession = []
        pending = []
        context = ""
    }

    func end() {
        flushTask?.cancel()
        flushTask = nil
        pending = []
        sessionId = nil
    }

    func ingest(text: String, speaker: String) {
        context += "\n\(speaker): \(text)"
        if context.count > 4_000 { context = String(context.suffix(3_000)) }
        guard settings.glossaryEnabled, let detector, let sessionId else { return }

        for candidate in detector.candidates(in: text) {
            let key = candidate.lowercased()
            guard handledThisSession.insert(key).inserted else { continue }
            if known.contains(key) {
                if let term = try? db.term(named: candidate), let termId = term.id, let definition = term.definition {
                    try? db.recordOccurrence(termId: termId, sessionId: sessionId, context: text)
                    onCard?(GlossaryCard(term: term.term, definition: definition, source: term.source, url: term.sourceURL))
                }
                continue
            }
            pending.append(candidate)
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil, !pending.isEmpty else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled else { return }
            let batch = Array(self.pending.prefix(8))
            self.pending.removeFirst(batch.count)
            await self.resolve(batch, context: String(self.context.suffix(1_800)))
            self.flushTask = nil
            self.scheduleFlush()
        }
    }

    // MARK: Lookup

    private struct LLMTerm: Decodable {
        let term: String
        let explain: Bool
        let definition: String?
        let used_reference: Bool?
    }

    private struct LLMTermsResponse: Decodable {
        let terms: [LLMTerm]
    }

    private func resolve(_ batch: [String], context: String) async {
        guard let sessionId else { return }
        var references: [String: WikiSummary] = [:]
        if settings.webLookup {
            let host = settings.language.wikipediaHost
            await withTaskGroup(of: (String, WikiSummary?).self) { group in
                for term in batch {
                    group.addTask { (term, await WikipediaLookup.summary(for: term, host: host)) }
                }
                for await (term, summary) in group {
                    if let summary { references[term.lowercased()] = summary }
                }
            }
        }

        if let llm = LLMFactory.make(settings: settings) {
            do {
                let response = try await llm.completeJSON(
                    LLMTermsResponse.self,
                    system: Self.systemPrompt,
                    user: Self.userPrompt(batch: batch, context: context, references: references))
                var answered: Set<String> = []
                for item in response.terms {
                    let key = item.term.lowercased()
                    answered.insert(key)
                    let ref = references[key]
                    if item.explain, let def = item.definition?.trimmingCharacters(in: .whitespacesAndNewlines), !def.isEmpty {
                        let usedRef = (item.used_reference ?? false) && ref != nil
                        store(term: item.term, definition: def, source: usedRef ? "wikipedia" : "llm",
                              url: usedRef ? ref?.url : nil, sessionId: sessionId, context: context, show: true)
                    } else {
                        store(term: item.term, definition: nil, source: "ignored", url: nil,
                              sessionId: sessionId, context: nil, show: false)
                    }
                }
                // Candidates the model skipped silently: treat as not worth explaining.
                for term in batch where !answered.contains(term.lowercased()) {
                    store(term: term, definition: nil, source: "ignored", url: nil, sessionId: sessionId, context: nil, show: false)
                }
                return
            } catch {
                onError?("Glossary: \(error.localizedDescription)")
                // fall back to reference-only below
            }
        }

        // No LLM: show Wikipedia definitions only (can't judge relevance, so nothing is marked ignored).
        for term in batch {
            guard let ref = references[term.lowercased()] else { continue }
            store(term: term, definition: WikipediaLookup.firstSentences(ref.extract), source: "wikipedia",
                  url: ref.url, sessionId: sessionId, context: context, show: true)
        }
    }

    private func store(term: String, definition: String?, source: String, url: String?,
                       sessionId: Int64, context: String?, show: Bool) {
        let record = TermRecord(id: nil, term: term, definition: definition, source: source, sourceURL: url, createdAt: Date())
        guard let saved = try? db.saveTerm(record) else { return }
        known.insert(term.lowercased())
        handledThisSession.insert(term.lowercased())
        if let id = saved.id, definition != nil {
            try? db.recordOccurrence(termId: id, sessionId: sessionId, context: context.map { String($0.suffix(300)) })
        }
        if show, let definition {
            onCard?(GlossaryCard(term: saved.term, definition: definition, source: source, url: url))
        }
    }

    static let systemPrompt = """
    You help someone follow a live conversation by explaining uncommon terms on screen.
    You get: candidate terms that were automatically flagged as rare, the recent transcript, and optional reference \
    extracts (from Wikipedia) for some candidates.
    For EACH candidate decide if a typical educated listener would benefit from an explanation: technical jargon, \
    acronyms, niche concepts, products/tools, uncommon words. Do NOT explain people's names, ordinary words, filler, \
    or garbled transcription errors (set explain=false for those).
    You may add up to 2 extra multi-word technical phrases from the transcript that deserve explanation.
    Definitions: at most 30 words, plain language, matching how the term is used in THIS conversation. If a reference \
    extract matches that meaning, base the definition on it and set used_reference=true; otherwise infer from context \
    and general knowledge and set used_reference=false.
    Reply with JSON only: {"terms":[{"term":"...","explain":true,"definition":"...","used_reference":false}]}
    """

    static func userPrompt(batch: [String], context: String, references: [String: WikiSummary]) -> String {
        var s = "Candidates: \(batch.joined(separator: ", "))\n\nRecent transcript:\n\(context)\n"
        let refs = batch.compactMap { term -> String? in
            guard let r = references[term.lowercased()] else { return nil }
            return "- \(term) → \(r.title): \(WikipediaLookup.firstSentences(r.extract, maxLength: 400))"
        }
        if !refs.isEmpty { s += "\nReference extracts:\n" + refs.joined(separator: "\n") }
        return s
    }
}
