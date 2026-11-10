import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            CaptureSettings().tabItem { Label("Listening", systemImage: "waveform") }
            AISettings().tabItem { Label("AI", systemImage: "sparkles") }
            GlossarySettings().tabItem { Label("Glossary", systemImage: "character.book.closed") }
            OverlaySettings().tabItem { Label("Overlay", systemImage: "macwindow.on.rectangle") }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 460)
    }
}

private struct CaptureSettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Audio sources") {
                Toggle("System audio (all apps)", isOn: $settings.captureSystemAudio)
                Toggle("Microphone (your voice)", isOn: $settings.captureMicrophone)
                Toggle("Echo cancellation", isOn: $settings.echoCancellation)
                    .disabled(!settings.captureMicrophone)
                Text("Turn on if you use speakers instead of headphones. Otherwise Cabin removes duplicated mic lines automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Your name", text: $settings.myName)
            }
            Section("Speech recognition (on-device)") {
                Picker("Whisper model", selection: $settings.whisperModel) {
                    ForEach(WhisperModelOption.all) { Text($0.label).tag($0.id) }
                }
                Picker("Language", selection: $settings.languageCode) {
                    ForEach(SupportedLanguage.all) { Text($0.name).tag($0.code) }
                }
                Text("Models download from Hugging Face the first time you start listening. Changes apply on next start.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Speakers") {
                Toggle("Identify speakers (diarization)", isOn: $settings.speakerDiarization)
                VStack(alignment: .leading) {
                    Slider(value: $settings.speakerMatchThreshold, in: 0.2...0.9, step: 0.05) {
                        Text("Voice matching")
                    } minimumValueLabel: { Text("Strict") } maximumValueLabel: { Text("Loose") }
                    Text("Too many duplicate speakers → move right. Different people merged → move left. Current: \(settings.speakerMatchThreshold, specifier: "%.2f")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(state.isRecording)
        .overlay(alignment: .bottom) {
            if state.isRecording {
                Text("Stop listening to change these settings.")
                    .font(.caption).padding(6)
                    .background(.thinMaterial, in: Capsule())
            }
        }
    }
}

private struct AISettings: View {
    @EnvironmentObject var settings: AppSettings
    @State private var apiKey = ""
    @State private var keySaved = false
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section("Provider") {
                Picker("LLM", selection: $settings.llmProvider) {
                    ForEach(LLMProvider.allCases) { Text($0.displayName).tag($0) }
                }
                switch settings.llmProvider {
                case .openAI:
                    TextField("Model", text: $settings.openAIModel)
                    TextField("API base URL", text: $settings.openAIBaseURL)
                    Text("Works with any OpenAI-compatible endpoint. Get a key at platform.openai.com.")
                        .font(.caption).foregroundStyle(.secondary)
                case .gemini:
                    TextField("Model", text: $settings.geminiModel)
                    Text("Get a key at aistudio.google.com.")
                        .font(.caption).foregroundStyle(.secondary)
                case .none:
                    Text("Without an LLM, Cabin still transcribes and shows Wikipedia definitions, but won't summarize.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if settings.llmProvider != .none {
                Section("API key (stored in your Keychain)") {
                    SecureField("API key", text: $apiKey)
                    HStack {
                        Button("Save key") {
                            keySaved = KeychainStore.write(apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                                           account: settings.llmProvider.keychainAccount)
                            testResult = keySaved ? "Saved." : "Could not save to Keychain."
                        }
                        Button("Test connection") { Task { await test() } }
                            .disabled(testing)
                        if testing { ProgressView().controlSize(.small) }
                    }
                    if let testResult {
                        Text(testResult).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            Section("Summaries") {
                Stepper("Update summary every \(Int(settings.summaryIntervalMinutes)) min while listening",
                        value: $settings.summaryIntervalMinutes, in: 1...30, step: 1)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadKey)
        .onChange(of: settings.llmProvider) { _, _ in loadKey() }
    }

    private func loadKey() {
        apiKey = KeychainStore.read(settings.llmProvider.keychainAccount) ?? ""
        testResult = nil
    }

    private func test() async {
        testing = true
        defer { testing = false }
        guard let client = LLMFactory.make(settings: settings) else {
            testResult = "Save an API key first."
            return
        }
        do {
            let reply = try await client.complete(system: "You are a connectivity check.",
                                                  user: "Reply with the single word: OK", json: false)
            testResult = "✓ \(settings.activeLLMModel) replied: \(reply.prefix(60))"
        } catch {
            testResult = "✗ \(error.localizedDescription)"
        }
    }
}

private struct GlossarySettings: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Rare keyword detection") {
                Toggle("Show definitions for uncommon terms", isOn: $settings.glossaryEnabled)
                Picker("Treat as common", selection: $settings.commonWordCutoff) {
                    Text("Top 5,000 words (explain more)").tag(5_000)
                    Text("Top 10,000 words").tag(10_000)
                    Text("Top 20,000 words").tag(20_000)
                    Text("Top 50,000 words (explain less)").tag(50_000)
                }
                Toggle("Look up definitions on Wikipedia", isOn: $settings.webLookup)
                Text("Terms are checked against Wikipedia, then the AI writes a short definition in the context of the conversation (or infers one). Each term is looked up once and cached.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cards") {
                Stepper("Show up to \(settings.maxCards) cards", value: $settings.maxCards, in: 1...10)
                Stepper(settings.cardLifetimeSeconds > 0
                        ? "Hide after \(Int(settings.cardLifetimeSeconds)) s"
                        : "Keep until dismissed",
                        value: $settings.cardLifetimeSeconds, in: 0...600, step: 15)
            }
        }
        .formStyle(.grouped)
    }
}

private struct OverlaySettings: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Window") {
                Toggle("Show overlay", isOn: $settings.overlayVisible)
                LabeledSlider(title: "Width", value: $settings.overlayWidth, range: 220...1000, format: "%.0f pt")
                LabeledSlider(title: "Height", value: $settings.overlayHeight, range: 120...1200, format: "%.0f pt")
                LabeledSlider(title: "Opacity", value: $settings.overlayOpacity, range: 0.15...1, format: "%.2f")
                LabeledSlider(title: "Text size", value: $settings.overlayFontSize, range: 10...24, format: "%.0f pt")
                Toggle("Click-through (mouse passes through the overlay)", isOn: $settings.overlayClickThrough)
                Text("While click-through is on, use the menu bar icon to turn it off again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Content") {
                Toggle("Live transcript", isOn: $settings.overlayShowTranscript)
                Toggle("Glossary cards", isOn: $settings.overlayShowGlossary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        HStack {
            Text(title).frame(width: 70, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: format, value)).monospacedDigit().frame(width: 64, alignment: .trailing)
        }
    }
}
