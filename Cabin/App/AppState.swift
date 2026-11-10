import AppKit
import Combine
import Foundation

/// Central coordinator: capture → chunking → transcription/diarization → speakers → DB → glossary & summaries.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var engineState: EngineState = .idle
    @Published private(set) var liveLines: [TranscriptLine] = []
    @Published private(set) var cards: [GlossaryCard] = []
    @Published private(set) var currentSessionId: Int64?
    @Published private(set) var backlog = 0
    @Published var lastError: String?
    /// Bumped whenever stored data changes, so open history views can refresh.
    @Published private(set) var dataVersion = 0

    let settings = AppSettings.shared
    let db: AppDatabase
    let engine = TranscriptionEngine()
    let registry: SpeakerRegistry
    let glossary: GlossaryService
    let summarizer: Summarizer

    private let monitor = AudioActivityMonitor()
    private var systemCapture: SystemAudioCapture?
    private var micCapture: MicrophoneCapture?
    private let systemQueue = DispatchQueue(label: "cabin.chunker.system", qos: .userInitiated)
    private let micQueue = DispatchQueue(label: "cabin.chunker.mic", qos: .userInitiated)
    private var systemChunker: UtteranceChunker?
    private var micChunker: UtteranceChunker?
    private var chunkContinuation: AsyncStream<AudioChunk>.Continuation?
    private var consumer: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var dedup = EchoDeduplicator()
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let database: AppDatabase
        do {
            database = try AppDatabase.makeDefault()
        } catch {
            NSLog("Cabin: failed to open database, using in-memory store: \(error)")
            database = try! AppDatabase.makeInMemory()
        }
        db = database
        registry = SpeakerRegistry(db: database, threshold: Float(AppSettings.shared.speakerMatchThreshold))
        glossary = GlossaryService(db: database, settings: AppSettings.shared)
        summarizer = Summarizer(db: database, settings: AppSettings.shared)

        glossary.onCard = { [weak self] card in self?.show(card) }
        glossary.onError = { [weak self] message in self?.lastError = message }

        settings.$speakerMatchThreshold
            .sink { [weak self] value in self?.registry.threshold = Float(value) }
            .store(in: &cancellables)
        settings.$myName
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshLiveLines() } }
            .store(in: &cancellables)
    }

    var statusText: String {
        switch engineState {
        case .downloading(let p): return "Downloading speech model… \(Int(p * 100))%"
        case .loading: return "Loading models…"
        case .failed(let message): return "Error: \(message)"
        case .idle, .ready:
            if isRecording { return backlog > 1 ? "Listening (\(backlog) queued)" : "Listening" }
            return isBusy ? "Finishing…" : "Paused"
        }
    }

    // MARK: Recording control

    func toggleRecording() {
        Task {
            if isRecording { await stop() } else { await start() }
        }
    }

    func start() async {
        guard !isRecording, !isBusy else { return }
        guard settings.captureSystemAudio || settings.captureMicrophone else {
            lastError = "Enable system audio and/or microphone capture in Settings."
            return
        }
        isBusy = true
        defer { isBusy = false }
        lastError = nil

        do {
            try await engine.load(model: settings.whisperModel, diarization: settings.speakerDiarization) { state in
                Task { @MainActor in AppState.shared.engineState = state }
            }
        } catch {
            engineState = .failed(error.localizedDescription)
            lastError = "Could not load speech models: \(error.localizedDescription)"
            return
        }

        do {
            try registry.reload()
            let session = try db.createSession()
            currentSessionId = session.id
            liveLines = []
            dedup = EchoDeduplicator()
            if let id = session.id { glossary.begin(sessionId: id) }

            let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
            chunkContinuation = continuation
            consumer = Task { [weak self] in
                for await chunk in stream {
                    guard let self else { break }
                    await self.process(chunk)
                }
            }
            monitor.start()

            if settings.captureSystemAudio {
                let chunker = UtteranceChunker(source: .system)
                chunker.onChunk = { [weak self] chunk in self?.enqueue(chunk, continuation) }
                let capture = SystemAudioCapture()
                let queue = systemQueue
                capture.onSamples = { samples in queue.async { chunker.append(samples) } }
                capture.onError = { [weak self] error in
                    Task { @MainActor in self?.lastError = "System audio stopped: \(error.localizedDescription)" }
                }
                try await capture.start()
                systemCapture = capture
                systemChunker = chunker
            }

            if settings.captureMicrophone {
                guard await MicrophoneCapture.requestAccess() else { throw CaptureError.microphoneDenied }
                let chunker = UtteranceChunker(source: .microphone)
                chunker.onChunk = { [weak self] chunk in self?.enqueue(chunk, continuation) }
                let capture = MicrophoneCapture()
                let queue = micQueue
                capture.onSamples = { samples in queue.async { chunker.append(samples) } }
                try capture.start(echoCancellation: settings.echoCancellation)
                micCapture = capture
                micChunker = chunker
            }

            isRecording = true
            scheduleSummaries()
        } catch {
            lastError = error.localizedDescription
            await teardown(summarize: false)
        }
    }

    func stop() async {
        guard isRecording, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        isRecording = false
        await teardown(summarize: true)
    }

    private nonisolated func enqueue(_ chunk: AudioChunk, _ continuation: AsyncStream<AudioChunk>.Continuation) {
        continuation.yield(chunk)
        Task { @MainActor in self.backlog += 1 }
    }

    private func teardown(summarize: Bool) async {
        summaryTask?.cancel()
        summaryTask = nil

        await systemCapture?.stop()
        micCapture?.stop()
        systemCapture = nil
        micCapture = nil

        // Flush partially-buffered speech, then let the queue drain.
        if let chunker = systemChunker { systemQueue.sync { chunker.flush() } }
        if let chunker = micChunker { micQueue.sync { chunker.flush() } }
        systemChunker = nil
        micChunker = nil
        chunkContinuation?.finish()
        chunkContinuation = nil
        await consumer?.value
        consumer = nil
        monitor.stop()
        glossary.end()
        backlog = 0

        if let id = currentSessionId {
            try? db.endSession(id: id)
            if summarize, LLMFactory.make(settings: settings) != nil {
                do { try await summarizer.update(sessionId: id) } catch { lastError = "Summary: \(error.localizedDescription)" }
            }
            try? db.deleteSessionIfEmpty(id: id)
        }
        currentSessionId = nil
        dataVersion += 1
    }

    private func scheduleSummaries() {
        summaryTask?.cancel()
        summaryTask = Task { [weak self] in
            while !Task.isCancelled {
                let minutes = max(1, AppSettings.shared.summaryIntervalMinutes)
                try? await Task.sleep(nanoseconds: UInt64(minutes * 60 * 1_000_000_000))
                guard !Task.isCancelled, let self, let id = self.currentSessionId else { return }
                guard LLMFactory.make(settings: self.settings) != nil else { continue }
                do {
                    if try await self.summarizer.update(sessionId: id) { self.dataVersion += 1 }
                } catch {
                    self.lastError = "Summary: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: Processing

    private func process(_ chunk: AudioChunk) async {
        defer { backlog = max(0, backlog - 1) }
        guard let sessionId = currentSessionId else { return }

        let recognized: [RecognizedSegment]
        do {
            recognized = try await engine.transcribe(
                chunk, language: settings.languageCode, diarize: settings.speakerDiarization)
        } catch {
            lastError = "Transcription failed: \(error.localizedDescription)"
            return
        }
        guard !recognized.isEmpty else { return }

        let isMic = chunk.source == .microphone
        let app = monitor.apps(from: chunk.startedAt, to: chunk.endedAt, input: isMic).first
        registry.beginChunk()

        for seg in recognized {
            do {
                let speakerId = try registry.resolve(source: chunk.source, localSpeaker: seg.localSpeaker,
                                                     embedding: seg.embedding)
                let start = chunk.startedAt.addingTimeInterval(seg.start)
                let end = chunk.startedAt.addingTimeInterval(max(seg.end, seg.start))
                let saved = try db.insertSegment(SegmentRecord(
                    id: nil, sessionId: sessionId, speakerId: speakerId, source: chunk.source,
                    appBundleID: app?.bundleID, appName: app?.name ?? (isMic ? "Microphone" : nil),
                    startedAt: start, endedAt: end, text: seg.text))
                guard let segmentId = saved.id else { continue }

                if settings.captureSystemAudio && settings.captureMicrophone && !settings.echoCancellation {
                    let echoes = dedup.add(id: segmentId, source: chunk.source, start: start, end: end, text: seg.text)
                    if !echoes.isEmpty {
                        try db.deleteSegments(ids: echoes)
                        liveLines.removeAll { echoes.contains($0.id) }
                        if echoes.contains(segmentId) { continue }
                    }
                }

                let label = try speakerLabel(speakerId, sessionId: sessionId)
                appendLive(TranscriptLine(id: segmentId, speakerId: speakerId, speakerLabel: label,
                                          appName: saved.appName, source: chunk.source, startedAt: start, text: seg.text))
                glossary.ingest(text: seg.text, speaker: label)
            } catch {
                lastError = "Saving transcript failed: \(error.localizedDescription)"
            }
        }
        dataVersion += 1
    }

    private func speakerLabel(_ speakerId: Int64?, sessionId: Int64) throws -> String {
        guard let speakerId else { return "Unknown" }
        let ordinal = try db.ordinal(sessionId: sessionId, speakerId: speakerId)
        guard let speaker = try db.writer.read({ db in try SpeakerRecord.fetchOne(db, key: speakerId) }) else {
            return "Unknown"
        }
        return SpeakerLabel.label(for: speaker, ordinal: ordinal, userName: settings.myName)
    }

    private func appendLive(_ line: TranscriptLine) {
        liveLines.append(line)
        if liveLines.count > 60 { liveLines.removeFirst(liveLines.count - 60) }
    }

    func refreshLiveLines() {
        guard let id = currentSessionId,
              let lines = try? db.transcript(sessionId: id, userName: settings.myName) else { return }
        liveLines = Array(lines.suffix(60))
    }

    // MARK: Glossary cards

    private func show(_ card: GlossaryCard) {
        cards.removeAll { $0.term.lowercased() == card.term.lowercased() }
        cards.insert(card, at: 0)
        let maxCards = max(1, settings.maxCards)
        if cards.count > maxCards {
            // Drop the oldest unpinned cards first.
            while cards.count > maxCards, let idx = cards.lastIndex(where: { !$0.pinned }) { cards.remove(at: idx) }
        }
        let id = card.id
        let lifetime = settings.cardLifetimeSeconds
        guard lifetime > 0 else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(lifetime * 1_000_000_000))
            self?.cards.removeAll { $0.id == id && !$0.pinned }
        }
    }

    func dismissCard(_ id: UUID) {
        cards.removeAll { $0.id == id }
    }

    func togglePin(_ id: UUID) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[i].pinned.toggle()
    }

    // MARK: Editing (from history UI)

    func renameSpeaker(_ id: Int64, to name: String?) {
        do { try db.renameSpeaker(id: id, name: name) } catch { lastError = error.localizedDescription }
        refreshLiveLines()
        dataVersion += 1
    }

    func mergeSpeaker(_ source: Int64, into target: Int64) {
        do {
            try db.mergeSpeaker(source, into: target)
            registry.forget(source)
        } catch { lastError = error.localizedDescription }
        refreshLiveLines()
        dataVersion += 1
    }

    func regenerateSummary(sessionId: Int64) async {
        do {
            try await summarizer.regenerate(sessionId: sessionId)
        } catch {
            lastError = "Summary: \(error.localizedDescription)"
        }
        dataVersion += 1
    }

    func deleteSession(_ id: Int64) {
        guard id != currentSessionId else { return }
        try? db.deleteSession(id: id)
        dataVersion += 1
    }

    func touchData() { dataVersion += 1 }
}
