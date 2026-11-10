import Foundation
import Combine

enum LLMProvider: String, CaseIterable, Identifiable, Codable {
    case openAI
    case gemini
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI (ChatGPT)"
        case .gemini: return "Google Gemini"
        case .none: return "None (no summaries / inferred definitions)"
        }
    }

    var keychainAccount: String { "llm-key-\(rawValue)" }
}

/// A transcription language. Adding a language = add an entry here plus a
/// `wordfreq-<code>.txt` resource (one word per line, most common first).
struct SupportedLanguage: Identifiable, Hashable {
    let code: String      // Whisper language code
    let name: String
    var id: String { code }

    var wordListResource: String { "wordfreq-\(code)" }
    var wikipediaHost: String { "\(code).wikipedia.org" }

    static let all: [SupportedLanguage] = [
        SupportedLanguage(code: "en", name: "English"),
        // e.g. SupportedLanguage(code: "vi", name: "Tiếng Việt"),
    ]

    static func find(_ code: String) -> SupportedLanguage {
        all.first { $0.code == code } ?? all[0]
    }
}

struct WhisperModelOption: Identifiable, Hashable {
    let id: String
    let label: String

    static let all: [WhisperModelOption] = [
        WhisperModelOption(id: "large-v3-v20240930_turbo", label: "Large v3 Turbo (best, ~1.6 GB)"),
        WhisperModelOption(id: "large-v3-v20240930_626MB", label: "Large v3 Turbo compressed (~630 MB)"),
        WhisperModelOption(id: "small.en", label: "Small English (~250 MB)"),
        WhisperModelOption(id: "base.en", label: "Base English (~80 MB, fastest)"),
    ]
}

/// All user preferences, persisted in UserDefaults. API keys live in the Keychain (see `KeychainStore`).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    // MARK: LLM
    @Published var llmProvider: LLMProvider { didSet { set(llmProvider.rawValue, "llmProvider") } }
    @Published var openAIModel: String { didSet { set(openAIModel, "openAIModel") } }
    @Published var openAIBaseURL: String { didSet { set(openAIBaseURL, "openAIBaseURL") } }
    @Published var geminiModel: String { didSet { set(geminiModel, "geminiModel") } }

    // MARK: Capture & transcription
    @Published var captureSystemAudio: Bool { didSet { set(captureSystemAudio, "captureSystemAudio") } }
    @Published var captureMicrophone: Bool { didSet { set(captureMicrophone, "captureMicrophone") } }
    @Published var echoCancellation: Bool { didSet { set(echoCancellation, "echoCancellation") } }
    @Published var whisperModel: String { didSet { set(whisperModel, "whisperModel") } }
    @Published var languageCode: String { didSet { set(languageCode, "languageCode") } }
    @Published var speakerDiarization: Bool { didSet { set(speakerDiarization, "speakerDiarization") } }
    /// Cosine distance below which two voices are considered the same person (lower = stricter).
    @Published var speakerMatchThreshold: Double { didSet { set(speakerMatchThreshold, "speakerMatchThreshold") } }
    @Published var myName: String { didSet { set(myName, "myName") } }

    // MARK: Glossary
    @Published var glossaryEnabled: Bool { didSet { set(glossaryEnabled, "glossaryEnabled") } }
    /// Words ranked inside the top-N most common words are never treated as rare.
    @Published var commonWordCutoff: Int { didSet { set(commonWordCutoff, "commonWordCutoff") } }
    @Published var webLookup: Bool { didSet { set(webLookup, "webLookup") } }
    @Published var cardLifetimeSeconds: Double { didSet { set(cardLifetimeSeconds, "cardLifetimeSeconds") } }
    @Published var maxCards: Int { didSet { set(maxCards, "maxCards") } }

    // MARK: Summary
    @Published var summaryIntervalMinutes: Double { didSet { set(summaryIntervalMinutes, "summaryIntervalMinutes") } }

    // MARK: Overlay
    @Published var overlayVisible: Bool { didSet { set(overlayVisible, "overlayVisible") } }
    @Published var overlayWidth: Double { didSet { set(overlayWidth, "overlayWidth") } }
    @Published var overlayHeight: Double { didSet { set(overlayHeight, "overlayHeight") } }
    @Published var overlayOpacity: Double { didSet { set(overlayOpacity, "overlayOpacity") } }
    @Published var overlayFontSize: Double { didSet { set(overlayFontSize, "overlayFontSize") } }
    @Published var overlayClickThrough: Bool { didSet { set(overlayClickThrough, "overlayClickThrough") } }
    @Published var overlayShowTranscript: Bool { didSet { set(overlayShowTranscript, "overlayShowTranscript") } }
    @Published var overlayShowGlossary: Bool { didSet { set(overlayShowGlossary, "overlayShowGlossary") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        llmProvider = LLMProvider(rawValue: defaults.string(forKey: "llmProvider") ?? "") ?? .openAI
        openAIModel = defaults.string(forKey: "openAIModel") ?? "gpt-5-mini"
        openAIBaseURL = defaults.string(forKey: "openAIBaseURL") ?? "https://api.openai.com/v1"
        geminiModel = defaults.string(forKey: "geminiModel") ?? "gemini-2.5-flash"

        captureSystemAudio = defaults.object(forKey: "captureSystemAudio") as? Bool ?? true
        captureMicrophone = defaults.object(forKey: "captureMicrophone") as? Bool ?? true
        echoCancellation = defaults.object(forKey: "echoCancellation") as? Bool ?? false
        whisperModel = defaults.string(forKey: "whisperModel") ?? "large-v3-v20240930_turbo"
        languageCode = defaults.string(forKey: "languageCode") ?? "en"
        speakerDiarization = defaults.object(forKey: "speakerDiarization") as? Bool ?? true
        speakerMatchThreshold = defaults.object(forKey: "speakerMatchThreshold") as? Double ?? 0.5
        myName = defaults.string(forKey: "myName") ?? "Me"

        glossaryEnabled = defaults.object(forKey: "glossaryEnabled") as? Bool ?? true
        commonWordCutoff = defaults.object(forKey: "commonWordCutoff") as? Int ?? 20_000
        webLookup = defaults.object(forKey: "webLookup") as? Bool ?? true
        cardLifetimeSeconds = defaults.object(forKey: "cardLifetimeSeconds") as? Double ?? 90
        maxCards = defaults.object(forKey: "maxCards") as? Int ?? 4

        summaryIntervalMinutes = defaults.object(forKey: "summaryIntervalMinutes") as? Double ?? 3

        overlayVisible = defaults.object(forKey: "overlayVisible") as? Bool ?? true
        overlayWidth = defaults.object(forKey: "overlayWidth") as? Double ?? 380
        overlayHeight = defaults.object(forKey: "overlayHeight") as? Double ?? 420
        overlayOpacity = defaults.object(forKey: "overlayOpacity") as? Double ?? 0.92
        overlayFontSize = defaults.object(forKey: "overlayFontSize") as? Double ?? 13
        overlayClickThrough = defaults.object(forKey: "overlayClickThrough") as? Bool ?? false
        overlayShowTranscript = defaults.object(forKey: "overlayShowTranscript") as? Bool ?? true
        overlayShowGlossary = defaults.object(forKey: "overlayShowGlossary") as? Bool ?? true
    }

    var language: SupportedLanguage { SupportedLanguage.find(languageCode) }

    var activeLLMModel: String {
        switch llmProvider {
        case .openAI: return openAIModel
        case .gemini: return geminiModel
        case .none: return ""
        }
    }

    private func set(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
