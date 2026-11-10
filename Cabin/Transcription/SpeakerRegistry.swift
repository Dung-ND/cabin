import Foundation

/// Matches voice embeddings to known speakers (persisted in the DB), creating new ones as needed.
/// Speakers are global, so a name you give "Speaker 2" is remembered the next time that voice is heard.
final class SpeakerRegistry {
    private let db: AppDatabase
    private var speakers: [Int64: (embedding: [Float], count: Int)] = [:]
    private(set) var userSpeakerId: Int64?
    /// Remembers the last speaker heard on system audio, for chunks too short to diarize.
    private var lastSystemSpeaker: Int64?
    private var chunkCache: [Int: Int64] = [:]

    var threshold: Float

    init(db: AppDatabase, threshold: Float) {
        self.db = db
        self.threshold = threshold
    }

    func reload() throws {
        speakers = [:]
        for s in try db.allSpeakers() {
            guard let id = s.id else { continue }
            if s.isUser { userSpeakerId = id; continue }
            speakers[id] = (s.embeddingVector, s.embeddingCount)
        }
        if userSpeakerId == nil { userSpeakerId = try db.userSpeaker().id }
        lastSystemSpeaker = nil
    }

    func beginChunk() { chunkCache = [:] }

    /// Resolves the global speaker id for a recognized segment.
    func resolve(source: AudioSourceKind, localSpeaker: Int?, embedding: [Float]?) throws -> Int64? {
        if source == .microphone { return userSpeakerId }

        if let localSpeaker, let cached = chunkCache[localSpeaker] { return cached }

        guard let embedding, !embedding.isEmpty else {
            if let lastSystemSpeaker { return lastSystemSpeaker }
            return try createSpeaker(embedding: [])
        }

        let id: Int64
        if let best = nearest(to: embedding), best.1 <= threshold {
            id = best.0
            update(id: best.0, with: embedding)
        } else {
            id = try createSpeaker(embedding: embedding)
        }
        if let localSpeaker { chunkCache[localSpeaker] = id }
        lastSystemSpeaker = id
        return id
    }

    /// Call after the user merges/deletes speakers so in-memory state matches the DB.
    func forget(_ id: Int64) {
        speakers[id] = nil
        if lastSystemSpeaker == id { lastSystemSpeaker = nil }
    }

    func nearest(to embedding: [Float]) -> (Int64, Float)? {
        var best: (Int64, Float)?
        for (id, s) in speakers where s.embedding.count == embedding.count {
            let d = Self.cosineDistance(embedding, s.embedding)
            if best == nil || d < best!.1 { best = (id, d) }
        }
        return best
    }

    private func createSpeaker(embedding: [Float]) throws -> Int64? {
        let s = try db.insertSpeaker(embedding: embedding)
        guard let id = s.id else { return nil }
        speakers[id] = (embedding, embedding.isEmpty ? 0 : 1)
        lastSystemSpeaker = id
        return id
    }

    private func update(id: Int64, with embedding: [Float]) {
        guard let current = speakers[id] else { return }
        // Running mean, capped so the profile can still adapt slowly.
        let n = Float(min(current.count, 50))
        let updated: [Float]
        if current.embedding.count == embedding.count {
            updated = zip(current.embedding, embedding).map { ($0 * n + $1) / (n + 1) }
        } else {
            updated = embedding
        }
        let count = current.count + 1
        speakers[id] = (updated, count)
        try? db.updateSpeakerEmbedding(id: id, embedding: updated, count: count)
    }

    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 1 }
        return 1 - dot / (na.squareRoot() * nb.squareRoot())
    }
}
