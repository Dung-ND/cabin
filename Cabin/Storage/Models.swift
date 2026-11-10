import Foundation
import GRDB

struct SessionRecord: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "session"
    var id: Int64?
    var startedAt: Date
    var endedAt: Date?
    var title: String?
    var summary: String?
    var summaryUpdatedAt: Date?
    /// Id of the last segment folded into `summary` (for incremental summaries).
    var summarizedThroughSegmentId: Int64?

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return "Session \(startedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

struct SpeakerRecord: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "speaker"
    var id: Int64?
    /// User-assigned name; nil means "Speaker N" (N is per-session).
    var name: String?
    var isUser: Bool
    /// Running mean voice embedding (Float32 array as raw bytes).
    var embedding: Data?
    var embeddingCount: Int
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    var embeddingVector: [Float] {
        get { embedding.map(Self.floats(from:)) ?? [] }
        set { embedding = Self.data(from: newValue) }
    }

    static func floats(from data: Data) -> [Float] {
        data.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
    }

    static func data(from floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// Links a speaker to a session and stores their per-session ordinal ("Speaker 2").
struct SessionSpeakerRecord: Codable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sessionSpeaker"
    var sessionId: Int64
    var speakerId: Int64
    var ordinal: Int
}

enum AudioSourceKind: String, Codable, Hashable {
    case system
    case microphone
}

struct SegmentRecord: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "segment"
    var id: Int64?
    var sessionId: Int64
    var speakerId: Int64?
    var source: AudioSourceKind
    var appBundleID: String?
    var appName: String?
    var startedAt: Date
    var endedAt: Date
    var text: String

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct TermRecord: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "term"
    var id: Int64?
    var term: String
    /// nil when the term was checked and judged not worth explaining.
    var definition: String?
    /// "wikipedia", "llm" (inferred from context) or "ignored".
    var source: String
    var sourceURL: String?
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    var isIgnored: Bool { definition == nil }
}

struct TermOccurrenceRecord: Codable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "termOccurrence"
    var termId: Int64
    var sessionId: Int64
    var firstSeenAt: Date
    var context: String?
}

/// A transcript line ready for display (segment + resolved names).
struct TranscriptLine: Identifiable, Hashable {
    let id: Int64
    let speakerId: Int64?
    let speakerLabel: String
    let appName: String?
    let source: AudioSourceKind
    let startedAt: Date
    let text: String
}

/// A speaker as they appear in one session.
struct SessionSpeaker: Identifiable, Hashable {
    let speaker: SpeakerRecord
    let ordinal: Int
    var id: Int64 { speaker.id ?? -1 }
}
