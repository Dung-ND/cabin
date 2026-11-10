import Foundation
import WhisperKit
import SpeakerKit

/// One stretch of text attributed to a single (chunk-local) speaker.
struct RecognizedSegment {
    var text: String
    var start: TimeInterval        // seconds from chunk start
    var end: TimeInterval
    /// Diarization cluster id inside this chunk (nil = unknown / mic).
    var localSpeaker: Int?
    /// Voice embedding of that cluster, used to match speakers across chunks and sessions.
    var embedding: [Float]?
}

enum EngineState: Equatable {
    case idle
    case downloading(Double)
    case loading
    case ready
    case failed(String)
}

/// Runs WhisperKit (speech-to-text) and SpeakerKit (who spoke when) fully on-device.
actor TranscriptionEngine {
    private var whisper: WhisperKit?
    private var speakerKit: SpeakerKit?
    private var loadedModel: String?

    func load(model: String, diarization: Bool, onState: @escaping @Sendable (EngineState) -> Void) async throws {
        if whisper == nil || loadedModel != model {
            whisper = nil
            onState(.downloading(0))
            let folder = try await WhisperKit.download(variant: model, progressCallback: { progress in
                onState(.downloading(progress.fractionCompleted))
            })
            onState(.loading)
            let config = WhisperKitConfig(
                model: model,
                modelFolder: folder.path,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false)
            whisper = try await WhisperKit(config)
            loadedModel = model
        }
        if diarization && speakerKit == nil {
            onState(.loading)
            let kit = try await SpeakerKit(PyannoteConfig(
                modelRepo: "argmaxinc/speakerkit-coreml", download: true, load: true, verbose: false, logLevel: .error))
            speakerKit = kit
        }
        onState(.ready)
    }

    var isReady: Bool { whisper != nil }

    func transcribe(_ chunk: AudioChunk, language: String, diarize: Bool) async throws -> [RecognizedSegment] {
        guard let whisper else { return [] }
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: true,
            chunkingStrategy: .vad)
        let results = try await whisper.transcribe(audioArray: chunk.samples, decodeOptions: options)

        // Diarize only system audio with enough speech to be meaningful.
        if diarize, chunk.source == .system, chunk.duration >= 2, let speakerKit {
            do {
                let diarization = try await speakerKit.diarize(audioArray: chunk.samples)
                let groups = diarization.addSpeakerInfo(to: results, strategy: .subsegment)
                var out: [RecognizedSegment] = []
                for seg in groups.flatMap({ $0 }) {
                    let text = TextCleaner.clean(seg.text)
                    guard !text.isEmpty else { continue }
                    let id = seg.speaker.speakerId ?? seg.speaker.speakerIds.first
                    out.append(RecognizedSegment(
                        text: text,
                        start: TimeInterval(seg.startTime),
                        end: TimeInterval(seg.endTime),
                        localSpeaker: id,
                        embedding: id.flatMap { diarization.speakerCentroidEmbeddings[$0] }))
                }
                return Self.mergeAdjacent(out)
            } catch {
                // Fall through to plain transcription.
            }
        }

        let segments = results.flatMap(\.segments)
        let out = segments.compactMap { seg -> RecognizedSegment? in
            let text = TextCleaner.clean(seg.text)
            guard !text.isEmpty, seg.noSpeechProb < 0.8 else { return nil }
            return RecognizedSegment(text: text, start: TimeInterval(seg.start), end: TimeInterval(seg.end),
                                     localSpeaker: nil, embedding: nil)
        }
        return Self.mergeAdjacent(out)
    }

    /// Joins consecutive segments from the same speaker into one line.
    static func mergeAdjacent(_ segments: [RecognizedSegment]) -> [RecognizedSegment] {
        var out: [RecognizedSegment] = []
        for seg in segments {
            if var last = out.last, last.localSpeaker == seg.localSpeaker {
                last.text += " " + seg.text
                last.end = seg.end
                out[out.count - 1] = last
            } else {
                out.append(seg)
            }
        }
        return out
    }
}

enum TextCleaner {
    private static let specialTokens = try! NSRegularExpression(pattern: "<\\|[^|]*\\|>")
    private static let annotations = try! NSRegularExpression(pattern: "[\\[\\(][^\\]\\)]{0,40}[\\]\\)]")
    /// Phrases Whisper commonly hallucinates on silence or music.
    private static let hallucinations: Set<String> = [
        "thank you.", "thank you", "thanks for watching!", "thanks for watching.", "you", "bye.", ".",
        "thank you for watching.", "please subscribe.", "subtitles by the amara.org community",
    ]

    static func clean(_ raw: String) -> String {
        var s = raw
        let range = { NSRange(s.startIndex..., in: s) }
        s = specialTokens.stringByReplacingMatches(in: s, range: range(), withTemplate: "")
        s = annotations.stringByReplacingMatches(in: s, range: range(), withTemplate: "")
        s = s.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if hallucinations.contains(s.lowercased()) { return "" }
        guard s.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return s
    }
}
