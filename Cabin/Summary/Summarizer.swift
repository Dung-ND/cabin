import Foundation

/// Builds a running summary of a session with the configured LLM, folding in new transcript incrementally.
@MainActor
final class Summarizer {
    private let db: AppDatabase
    private let settings: AppSettings
    private var running: Set<Int64> = []

    init(db: AppDatabase, settings: AppSettings) {
        self.db = db
        self.settings = settings
    }

    private struct Response: Decodable {
        let title: String?
        let summary: String
    }

    /// Folds transcript added since the last summary into the session summary.
    /// Returns false if nothing was done (no LLM, nothing new, or already running).
    @discardableResult
    func update(sessionId: Int64) async throws -> Bool {
        guard let session = try db.session(id: sessionId) else { return false }
        return try await fold(sessionId: sessionId, previous: session.summary,
                              afterId: session.summarizedThroughSegmentId)
    }

    /// Rebuilds the summary from the whole transcript.
    func regenerate(sessionId: Int64) async throws {
        _ = try await fold(sessionId: sessionId, previous: nil, afterId: nil)
    }

    private func fold(sessionId: Int64, previous: String?, afterId: Int64?) async throws -> Bool {
        guard let llm = LLMFactory.make(settings: settings) else { throw LLMError.missingKey(settings.llmProvider) }
        guard running.insert(sessionId).inserted else { return false }
        defer { running.remove(sessionId) }

        let lines = try db.transcript(sessionId: sessionId, afterId: afterId, userName: settings.myName)
        guard !lines.isEmpty else { return false }

        // Long transcripts are folded in pieces so each request stays a manageable size.
        var summary = previous
        var title: String?
        for piece in Self.pieces(lines, maxChars: 40_000) {
            let response = try await llm.completeJSON(
                Response.self,
                system: Self.systemPrompt,
                user: Self.userPrompt(previous: summary, transcript: piece.text))
            summary = response.summary
            if let t = response.title, !t.isEmpty { title = t }
            try db.updateSummary(sessionId: sessionId, title: title, summary: response.summary, throughSegmentId: piece.lastId)
        }
        return true
    }

    static func format(_ line: TranscriptLine) -> String {
        let time = line.startedAt.formatted(date: .omitted, time: .standard)
        let app = line.appName.map { " (\($0))" } ?? ""
        return "[\(time)] \(line.speakerLabel)\(app): \(line.text)"
    }

    static func pieces(_ lines: [TranscriptLine], maxChars: Int) -> [(text: String, lastId: Int64)] {
        var out: [(text: String, lastId: Int64)] = []
        var current = ""
        var lastId: Int64 = 0
        for line in lines {
            let f = format(line)
            if !current.isEmpty, current.count + f.count > maxChars {
                out.append((text: current, lastId: lastId))
                current = ""
            }
            current += f + "\n"
            lastId = line.id
        }
        if !current.isEmpty { out.append((text: current, lastId: lastId)) }
        return out
    }

    static let systemPrompt = """
    You keep running notes of everything a person hears and says on their Mac (meetings, videos, calls, podcasts).
    Transcript lines look like: [time] Speaker (App): text. "App" is where the audio came from; the person's own voice \
    comes from the microphone and is labelled with their name. Speaker labels like "Speaker 2" are automatic and may \
    be imperfect.
    Update the existing summary (if any) so it also covers the new transcript. Reply with JSON only:
    {"title": "<at most 8 words>", "summary": "<markdown>"}
    The markdown summary uses these sections, omitting empty ones:
    ## Overview (2-4 sentences)
    ## Key points (bullets; attribute to speakers when useful)
    ## Decisions
    ## Action items (- [ ] Owner: task)
    ## Sources (which apps / contexts were heard)
    Keep it under 450 words. Write in the language of the transcript.
    """

    static func userPrompt(previous: String?, transcript: String) -> String {
        """
        Existing summary:
        \(previous?.isEmpty == false ? previous! : "(none yet)")

        New transcript:
        \(transcript)
        """
    }
}
