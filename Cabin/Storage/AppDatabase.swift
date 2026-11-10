import Foundation
import GRDB

/// Local SQLite storage: sessions, speakers, transcript segments, glossary terms.
final class AppDatabase {
    let writer: DatabaseQueue

    static func makeDefault() throws -> AppDatabase {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Cabin", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return try AppDatabase(DatabaseQueue(path: dir.appendingPathComponent("cabin.sqlite").path))
    }

    static func makeInMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    init(_ writer: DatabaseQueue) throws {
        self.writer = writer
        try migrator.migrate(writer)
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "session") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("endedAt", .datetime)
                t.column("title", .text)
                t.column("summary", .text)
                t.column("summaryUpdatedAt", .datetime)
                t.column("summarizedThroughSegmentId", .integer)
            }
            try db.create(table: "speaker") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text)
                t.column("isUser", .boolean).notNull().defaults(to: false)
                t.column("embedding", .blob)
                t.column("embeddingCount", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "sessionSpeaker") { t in
                t.column("sessionId", .integer).notNull().references("session", onDelete: .cascade)
                t.column("speakerId", .integer).notNull().references("speaker", onDelete: .cascade)
                t.column("ordinal", .integer).notNull()
                t.primaryKey(["sessionId", "speakerId"])
            }
            try db.create(table: "segment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sessionId", .integer).notNull().indexed().references("session", onDelete: .cascade)
                t.column("speakerId", .integer).indexed().references("speaker", onDelete: .setNull)
                t.column("source", .text).notNull()
                t.column("appBundleID", .text)
                t.column("appName", .text)
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime).notNull()
                t.column("text", .text).notNull()
            }
            try db.create(virtualTable: "segmentFts", using: FTS5()) { t in
                t.synchronize(withTable: "segment")
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("text")
            }
            try db.create(table: "term") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("term", .text).notNull().unique(onConflict: .ignore).collate(.nocase)
                t.column("definition", .text)
                t.column("source", .text).notNull()
                t.column("sourceURL", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "termOccurrence") { t in
                t.column("termId", .integer).notNull().references("term", onDelete: .cascade)
                t.column("sessionId", .integer).notNull().references("session", onDelete: .cascade)
                t.column("firstSeenAt", .datetime).notNull()
                t.column("context", .text)
                t.primaryKey(["termId", "sessionId"])
            }
        }
        return m
    }
}

// MARK: - Sessions

extension AppDatabase {
    func createSession(startedAt: Date = Date()) throws -> SessionRecord {
        try writer.write { db in
            var s = SessionRecord(id: nil, startedAt: startedAt)
            try s.insert(db)
            return s
        }
    }

    func endSession(id: Int64, at date: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE session SET endedAt = ? WHERE id = ?", arguments: [date, id])
        }
    }

    func session(id: Int64) throws -> SessionRecord? {
        try writer.read { db in try SessionRecord.fetchOne(db, key: id) }
    }

    func sessions() throws -> [SessionRecord] {
        try writer.read { db in
            try SessionRecord.order(Column("startedAt").desc).fetchAll(db)
        }
    }

    func updateSummary(sessionId: Int64, title: String?, summary: String, throughSegmentId: Int64?) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE session SET title = COALESCE(?, title), summary = ?, summaryUpdatedAt = ?,
                    summarizedThroughSegmentId = COALESCE(?, summarizedThroughSegmentId)
                WHERE id = ?
                """,
                arguments: [title, summary, Date(), throughSegmentId, sessionId])
        }
    }

    func renameSession(id: Int64, title: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE session SET title = ? WHERE id = ?", arguments: [title, id])
        }
    }

    func deleteSession(id: Int64) throws {
        _ = try writer.write { db in try SessionRecord.deleteOne(db, key: id) }
    }

    /// Deletes sessions that have no transcript at all (e.g. started and stopped immediately).
    func deleteSessionIfEmpty(id: Int64) throws {
        try writer.write { db in
            let count = try SegmentRecord.filter(Column("sessionId") == id).fetchCount(db)
            if count == 0 { _ = try SessionRecord.deleteOne(db, key: id) }
        }
    }
}

// MARK: - Speakers

extension AppDatabase {
    func allSpeakers() throws -> [SpeakerRecord] {
        try writer.read { db in try SpeakerRecord.fetchAll(db) }
    }

    func userSpeaker() throws -> SpeakerRecord {
        try writer.write { db in
            if let s = try SpeakerRecord.filter(Column("isUser") == true).fetchOne(db) { return s }
            var s = SpeakerRecord(id: nil, name: nil, isUser: true, embedding: nil, embeddingCount: 0, createdAt: Date())
            try s.insert(db)
            return s
        }
    }

    func insertSpeaker(embedding: [Float]) throws -> SpeakerRecord {
        try writer.write { db in
            var s = SpeakerRecord(id: nil, name: nil, isUser: false,
                                  embedding: SpeakerRecord.data(from: embedding),
                                  embeddingCount: embedding.isEmpty ? 0 : 1, createdAt: Date())
            try s.insert(db)
            return s
        }
    }

    func updateSpeakerEmbedding(id: Int64, embedding: [Float], count: Int) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE speaker SET embedding = ?, embeddingCount = ? WHERE id = ?",
                           arguments: [SpeakerRecord.data(from: embedding), count, id])
        }
    }

    func renameSpeaker(id: Int64, name: String?) throws {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try writer.write { db in
            try db.execute(sql: "UPDATE speaker SET name = ? WHERE id = ?",
                           arguments: [(trimmed?.isEmpty ?? true) ? nil : trimmed, id])
        }
    }

    /// Moves every segment of `source` onto `target` and deletes `source`.
    func mergeSpeaker(_ source: Int64, into target: Int64) throws {
        guard source != target else { return }
        try writer.write { db in
            try db.execute(sql: "UPDATE segment SET speakerId = ? WHERE speakerId = ?", arguments: [target, source])
            try db.execute(sql: """
                INSERT OR IGNORE INTO sessionSpeaker (sessionId, speakerId, ordinal)
                SELECT sessionId, ?, ordinal FROM sessionSpeaker WHERE speakerId = ?
                """, arguments: [target, source])
            _ = try SpeakerRecord.deleteOne(db, key: source)
        }
    }

    /// Returns the per-session ordinal for a speaker, assigning the next one if new.
    func ordinal(sessionId: Int64, speakerId: Int64) throws -> Int {
        try writer.write { db in
            if let row = try SessionSpeakerRecord
                .filter(Column("sessionId") == sessionId && Column("speakerId") == speakerId)
                .fetchOne(db) {
                return row.ordinal
            }
            let maxOrdinal = try Int.fetchOne(db, sql: "SELECT MAX(ordinal) FROM sessionSpeaker WHERE sessionId = ?",
                                              arguments: [sessionId]) ?? 0
            let rec = SessionSpeakerRecord(sessionId: sessionId, speakerId: speakerId, ordinal: maxOrdinal + 1)
            try rec.insert(db)
            return rec.ordinal
        }
    }

    /// Speakers that appear in a session, with their per-session ordinal.
    func speakers(sessionId: Int64) throws -> [SessionSpeaker] {
        try writer.read { db in
            let links = try SessionSpeakerRecord.filter(Column("sessionId") == sessionId)
                .order(Column("ordinal")).fetchAll(db)
            return try links.compactMap { link in
                guard let s = try SpeakerRecord.fetchOne(db, key: link.speakerId) else { return nil }
                return SessionSpeaker(speaker: s, ordinal: link.ordinal)
            }
        }
    }
}

// MARK: - Segments

extension AppDatabase {
    func insertSegment(_ segment: SegmentRecord) throws -> SegmentRecord {
        try writer.write { db in
            var s = segment
            try s.insert(db)
            return s
        }
    }

    func deleteSegments(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        _ = try writer.write { db in try SegmentRecord.deleteAll(db, keys: ids) }
    }

    func segments(sessionId: Int64, afterId: Int64? = nil) throws -> [SegmentRecord] {
        try writer.read { db in
            var req = SegmentRecord.filter(Column("sessionId") == sessionId)
            if let afterId { req = req.filter(Column("id") > afterId) }
            return try req.order(Column("startedAt"), Column("id")).fetchAll(db)
        }
    }

    /// Transcript lines with speaker labels resolved for display.
    func transcript(sessionId: Int64, afterId: Int64? = nil, userName: String) throws -> [TranscriptLine] {
        let segs = try segments(sessionId: sessionId, afterId: afterId)
        let speakerInfo = try speakers(sessionId: sessionId)
        var labels: [Int64: String] = [:]
        for entry in speakerInfo {
            labels[entry.id] = SpeakerLabel.label(for: entry.speaker, ordinal: entry.ordinal, userName: userName)
        }
        return segs.compactMap { seg in
            guard let id = seg.id else { return nil }
            return TranscriptLine(
                id: id,
                speakerId: seg.speakerId,
                speakerLabel: seg.speakerId.flatMap { labels[$0] } ?? "Unknown",
                appName: seg.appName,
                source: seg.source,
                startedAt: seg.startedAt,
                text: seg.text)
        }
    }

    /// Full-text search across all transcripts. Returns (session, matching segment).
    func search(_ query: String, limit: Int = 200) throws -> [(SessionRecord, SegmentRecord)] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        return try writer.read { db in
            let segs = try SegmentRecord.fetchAll(db, sql: """
                SELECT segment.* FROM segment
                JOIN segmentFts ON segmentFts.rowid = segment.id AND segmentFts MATCH ?
                ORDER BY segment.startedAt DESC LIMIT ?
                """, arguments: [pattern, limit])
            return try segs.compactMap { seg in
                guard let s = try SessionRecord.fetchOne(db, key: seg.sessionId) else { return nil }
                return (s, seg)
            }
        }
    }
}

// MARK: - Glossary terms

extension AppDatabase {
    func term(named name: String) throws -> TermRecord? {
        try writer.read { db in
            try TermRecord.fetchOne(db, sql: "SELECT * FROM term WHERE term = ? COLLATE NOCASE", arguments: [name])
        }
    }

    func knownTermNames() throws -> Set<String> {
        try writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT lower(term) FROM term"))
        }
    }

    @discardableResult
    func saveTerm(_ term: TermRecord) throws -> TermRecord {
        try writer.write { db in
            if let existing = try TermRecord.fetchOne(db, sql: "SELECT * FROM term WHERE term = ? COLLATE NOCASE",
                                                      arguments: [term.term]) {
                var updated = existing
                updated.definition = term.definition
                updated.source = term.source
                updated.sourceURL = term.sourceURL
                try updated.update(db)
                return updated
            }
            var t = term
            try t.insert(db)
            return t
        }
    }

    func recordOccurrence(termId: Int64, sessionId: Int64, context: String?) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO termOccurrence (termId, sessionId, firstSeenAt, context) VALUES (?, ?, ?, ?)
                """, arguments: [termId, sessionId, Date(), context])
        }
    }

    func terms(sessionId: Int64) throws -> [TermRecord] {
        try writer.read { db in
            try TermRecord.fetchAll(db, sql: """
                SELECT term.* FROM term JOIN termOccurrence o ON o.termId = term.id
                WHERE o.sessionId = ? AND term.definition IS NOT NULL ORDER BY o.firstSeenAt
                """, arguments: [sessionId])
        }
    }

    func allDefinedTerms() throws -> [TermRecord] {
        try writer.read { db in
            try TermRecord.filter(Column("definition") != nil).order(Column("term").collating(.nocase)).fetchAll(db)
        }
    }

    func deleteTerm(id: Int64) throws {
        _ = try writer.write { db in try TermRecord.deleteOne(db, key: id) }
    }
}

enum SpeakerLabel {
    static func label(for speaker: SpeakerRecord, ordinal: Int, userName: String) -> String {
        if let name = speaker.name, !name.isEmpty { return name }
        if speaker.isUser { return userName.isEmpty ? "Me" : userName }
        return "Speaker \(ordinal)"
    }
}
