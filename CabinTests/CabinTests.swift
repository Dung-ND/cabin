import XCTest
@testable import Cabin

final class RareWordDetectorTests: XCTestCase {
    private func detector() -> RareWordDetector {
        let common = ["the", "we", "should", "deploy", "this", "to", "and", "use", "for", "no", "yes", "meeting",
                      "today", "about", "talk", "let", "us", "new", "model", "cluster", "well", "known"]
        var ranks: [String: Int] = [:]
        for (i, w) in common.enumerated() { ranks[w] = i }
        return RareWordDetector(ranks: ranks, cutoff: 1_000)
    }

    func testFindsJargonAndAcronyms() {
        let found = detector().candidates(in: "We should deploy this to Kubernetes and use RAG for the LLMs today.")
        XCTAssertEqual(found, ["Kubernetes", "RAG", "LLM"])
    }

    func testSkipsCommonWordsInflectionsAndEmphasis() {
        let found = detector().candidates(in: "NO, YES, deployed models, deploying clusters, well-known meeting.")
        XCTAssertEqual(found, [])
    }

    func testDeduplicatesCaseInsensitively() {
        let found = detector().candidates(in: "Terraform terraform TERRAFORMs")
        XCTAssertEqual(found, ["Terraform"])
    }

    func testBundledWordListLoads() {
        let d = RareWordDetector.load(language: SupportedLanguage.find("en"), cutoff: 20_000,
                                      bundle: Bundle(for: AppState.self))
        XCTAssertTrue(d.isLoaded)
        XCTAssertTrue(d.isCommon("people"))
        XCTAssertFalse(d.isCommon("kubernetes"))
    }
}

final class ChunkerTests: XCTestCase {
    func testSplitsOnSilence() {
        var now = Date(timeIntervalSince1970: 0)
        let chunker = UtteranceChunker(source: .system, clock: { now })
        var chunks: [AudioChunk] = []
        chunker.onChunk = { chunks.append($0) }

        let rate = Int(PCMConverter.targetSampleRate)
        func feed(_ seconds: Double, amplitude: Float) {
            let n = Int(seconds * Double(rate))
            let samples = (0..<n).map { i in amplitude * sin(Float(i) * 0.1) }
            for start in stride(from: 0, to: n, by: 1600) {
                let slice = Array(samples[start..<min(n, start + 1600)])
                now = now.addingTimeInterval(Double(slice.count) / Double(rate))
                chunker.append(slice)
            }
        }
        feed(1.0, amplitude: 0)       // background
        feed(2.0, amplitude: 0.3)     // speech
        feed(1.0, amplitude: 0)       // pause → split
        feed(1.5, amplitude: 0.3)     // speech
        chunker.flush()

        XCTAssertEqual(chunks.count, 2)
        XCTAssertGreaterThan(chunks[0].duration, 2.0)
        XCTAssertLessThan(chunks[0].startedAt.timeIntervalSince1970, 1.05)
    }

    func testCapsLongSpeech() {
        let chunker = UtteranceChunker(source: .microphone)
        var chunks: [AudioChunk] = []
        chunker.onChunk = { chunks.append($0) }
        let samples = (0..<(16_000 * 40)).map { i in 0.3 * sin(Float(i) * 0.1) }
        chunker.append(samples)
        chunker.flush()
        XCTAssertEqual(chunks.count, 3) // 18 s + 18 s + 4 s
    }
}

final class EchoDeduplicatorTests: XCTestCase {
    func testDropsMicEchoOfSystemAudio() {
        var d = EchoDeduplicator()
        let t = Date()
        XCTAssertEqual(d.add(id: 1, source: .system, start: t, end: t + 3, text: "Let's review the quarterly roadmap now"), [])
        XCTAssertEqual(d.add(id: 2, source: .microphone, start: t + 0.5, end: t + 3.5, text: "let's review the quarterly roadmap"), [2])
        XCTAssertEqual(d.add(id: 3, source: .microphone, start: t + 4, end: t + 6, text: "Sounds good to me, thanks"), [])
    }

    func testSystemLineRemovesEarlierMicEcho() {
        var d = EchoDeduplicator()
        let t = Date()
        XCTAssertEqual(d.add(id: 1, source: .microphone, start: t, end: t + 3, text: "the deployment failed again last night"), [])
        XCTAssertEqual(d.add(id: 2, source: .system, start: t, end: t + 3, text: "The deployment failed again last night."), [1])
    }
}

final class DatabaseAndSpeakerTests: XCTestCase {
    func testSpeakerMatchingAndOrdinals() throws {
        let db = try AppDatabase.makeInMemory()
        let registry = SpeakerRegistry(db: db, threshold: 0.3)
        try registry.reload()
        let session = try db.createSession()
        let sid = try XCTUnwrap(session.id)

        registry.beginChunk()
        let a = try registry.resolve(source: .system, localSpeaker: 0, embedding: [1, 0, 0])
        let b = try registry.resolve(source: .system, localSpeaker: 1, embedding: [0, 1, 0])
        registry.beginChunk()
        let a2 = try registry.resolve(source: .system, localSpeaker: 5, embedding: [0.95, 0.05, 0])
        let me = try registry.resolve(source: .microphone, localSpeaker: nil, embedding: nil)

        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, a2)
        XCTAssertEqual(me, registry.userSpeakerId)

        XCTAssertEqual(try db.ordinal(sessionId: sid, speakerId: b!), 1)
        XCTAssertEqual(try db.ordinal(sessionId: sid, speakerId: a!), 2)
        XCTAssertEqual(try db.ordinal(sessionId: sid, speakerId: b!), 1)

        for (speaker, text) in [(a, "hello there"), (b, "kubernetes cluster upgrade")] {
            _ = try db.insertSegment(SegmentRecord(id: nil, sessionId: sid, speakerId: speaker, source: .system,
                                                   appBundleID: "us.zoom.xos", appName: "zoom.us",
                                                   startedAt: Date(), endedAt: Date(), text: text))
        }
        try db.renameSpeaker(id: a!, name: "Alice")
        let lines = try db.transcript(sessionId: sid, userName: "Me")
        XCTAssertEqual(lines.map(\.speakerLabel), ["Alice", "Speaker 1"])
        XCTAssertEqual(try db.search("kube").count, 1)

        try db.mergeSpeaker(b!, into: a!)
        XCTAssertEqual(try db.transcript(sessionId: sid, userName: "Me").map(\.speakerLabel), ["Alice", "Alice"])
    }

    func testTermCache() throws {
        let db = try AppDatabase.makeInMemory()
        let session = try db.createSession()
        let saved = try db.saveTerm(TermRecord(id: nil, term: "RAG", definition: "Retrieval-augmented generation.",
                                               source: "llm", sourceURL: nil, createdAt: Date()))
        try db.recordOccurrence(termId: saved.id!, sessionId: session.id!, context: "we use RAG")
        XCTAssertEqual(try db.term(named: "rag")?.definition, "Retrieval-augmented generation.")
        XCTAssertEqual(try db.knownTermNames(), ["rag"])
        XCTAssertEqual(try db.terms(sessionId: session.id!).count, 1)
    }
}

final class TextTests: XCTestCase {
    func testCleaner() {
        XCTAssertEqual(TextCleaner.clean("<|startoftranscript|> Hello [Music] world <|endoftext|>"), "Hello world")
        XCTAssertEqual(TextCleaner.clean(" Thank you. "), "")
        XCTAssertEqual(TextCleaner.clean("(upbeat music)"), "")
    }

    func testJSONExtraction() {
        XCTAssertEqual(OpenAIClient.extractJSONObject("```json\n{\"a\":1}\n```"), "{\"a\":1}")
    }
}
