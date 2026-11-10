import SwiftUI

struct OverlayView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings

    private var fontSize: CGFloat { CGFloat(settings.overlayFontSize) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let error = state.lastError {
                Text(error)
                    .font(.system(size: fontSize - 2))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .onTapGesture { state.lastError = nil }
                    .help("Click to dismiss")
            }
            if settings.overlayShowGlossary && !state.cards.isEmpty {
                VStack(spacing: 6) {
                    ForEach(state.cards) { card in
                        GlossaryCardView(card: card, fontSize: fontSize)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: state.cards)
            }
            if settings.overlayShowTranscript {
                transcript
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.isRecording ? Color.red : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(state.statusText)
                .font(.system(size: fontSize - 1, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                state.toggleRecording()
            } label: {
                Image(systemName: state.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.system(size: fontSize + 3))
            }
            .buttonStyle(.plain)
            .disabled(state.isBusy)
            .help(state.isRecording ? "Stop listening" : "Start listening")

            Menu {
                Toggle("Show transcript", isOn: $settings.overlayShowTranscript)
                Toggle("Show glossary", isOn: $settings.overlayShowGlossary)
                Toggle("Click-through", isOn: $settings.overlayClickThrough)
                Divider()
                Button("History…") { WindowManager.shared.showHistory() }
                Button("Settings…") { WindowManager.shared.showSettings() }
                Button("Hide overlay") { settings.overlayVisible = false }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: fontSize + 1))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if state.liveLines.isEmpty {
                        Text(state.isRecording ? "Waiting for speech…" : "Press ● to start listening.")
                            .font(.system(size: fontSize))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(state.liveLines) { line in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(line.speakerLabel).fontWeight(.semibold)
                                    .foregroundStyle(SpeakerColor.color(for: line.speakerId))
                                if let app = line.appName {
                                    Text("· \(app)").foregroundStyle(.secondary)
                                }
                            }
                            .font(.system(size: fontSize - 2))
                            Text(line.text)
                                .font(.system(size: fontSize))
                                .textSelection(.enabled)
                        }
                        .id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: state.liveLines.last?.id) { _, last in
                guard let last else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }
}

struct GlossaryCardView: View {
    @EnvironmentObject var state: AppState
    let card: GlossaryCard
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.term)
                    .font(.system(size: fontSize + 1, weight: .bold))
                Text(card.source == "wikipedia" ? "Wikipedia" : "inferred")
                    .font(.system(size: fontSize - 3))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { state.togglePin(card.id) } label: {
                    Image(systemName: card.pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.plain)
                .help(card.pinned ? "Unpin" : "Keep on screen")
                Button { state.dismissCard(card.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("Dismiss")
            }
            .font(.system(size: fontSize - 2))
            Text(card.definition)
                .font(.system(size: fontSize - 1))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let url = card.url, let link = URL(string: url) {
                Link("Read more", destination: link)
                    .font(.system(size: fontSize - 3))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12)))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

enum SpeakerColor {
    private static let palette: [Color] = [.blue, .purple, .orange, .teal, .pink, .green, .indigo, .brown]

    static func color(for id: Int64?) -> Color {
        guard let id else { return .secondary }
        return palette[Int(id % Int64(palette.count))]
    }
}
