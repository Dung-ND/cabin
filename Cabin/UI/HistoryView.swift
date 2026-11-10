import AppKit
import SwiftUI

enum SidebarItem: Hashable {
    case glossary
    case session(Int64)
}

struct HistoryView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @State private var sessions: [SessionRecord] = []
    @State private var selection: SidebarItem?
    @State private var query = ""
    @State private var results: [(SessionRecord, SegmentRecord)] = []

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if query.isEmpty {
                    Section("Library") {
                        Label("Glossary", systemImage: "character.book.closed").tag(SidebarItem.glossary)
                    }
                    Section("Sessions") {
                        ForEach(sessions) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    if s.id == state.currentSessionId {
                                        Circle().fill(.red).frame(width: 6, height: 6)
                                    }
                                    Text(s.displayTitle).lineLimit(1)
                                }
                                Text(s.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(SidebarItem.session(s.id ?? -1))
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    if let id = s.id { state.deleteSession(id) }
                                }
                                .disabled(s.id == state.currentSessionId)
                            }
                        }
                    }
                } else {
                    Section("\(results.count) matches") {
                        ForEach(Array(results.enumerated()), id: \.offset) { _, pair in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pair.1.text).lineLimit(2)
                                Text("\(pair.0.displayTitle) · \(pair.1.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(SidebarItem.session(pair.0.id ?? -1))
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search transcripts")
            .navigationSplitViewColumnWidth(min: 220, ideal: 270)
        } detail: {
            switch selection {
            case .glossary:
                GlossaryListView()
            case .session(let id):
                SessionDetailView(sessionId: id).id(id)
            case nil:
                ContentUnavailableView("Select a session", systemImage: "waveform",
                                       description: Text("Sessions are created each time you start listening."))
            }
        }
        .onAppear(perform: reload)
        .onChange(of: state.dataVersion) { _, _ in reload() }
        .onChange(of: query) { _, q in
            results = (try? state.db.search(q)) ?? []
        }
    }

    private func reload() {
        sessions = (try? state.db.sessions()) ?? []
        if selection == nil, let first = sessions.first?.id { selection = .session(first) }
        if !query.isEmpty { results = (try? state.db.search(query)) ?? [] }
    }
}

struct SessionDetailView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    let sessionId: Int64

    @State private var session: SessionRecord?
    @State private var lines: [TranscriptLine] = []
    @State private var speakers: [SessionSpeaker] = []
    @State private var terms: [TermRecord] = []
    @State private var title = ""
    @State private var tab = 0
    @State private var summarizing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding()
            Picker("", selection: $tab) {
                Text("Summary").tag(0)
                Text("Transcript (\(lines.count))").tag(1)
                Text("Speakers (\(speakers.count))").tag(2)
                Text("Terms (\(terms.count))").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            Divider().padding(.top, 8)
            Group {
                switch tab {
                case 0: summary
                case 1: transcript
                case 2: speakerList
                default: termList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear(perform: reload)
        .onChange(of: state.dataVersion) { _, _ in reload() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                    .onSubmit {
                        try? state.db.renameSession(id: sessionId, title: title)
                        state.touchData()
                    }
                if let s = session {
                    Text(dateRange(s)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                summarizing = true
                Task {
                    await state.regenerateSummary(sessionId: sessionId)
                    summarizing = false
                }
            } label: {
                if summarizing { ProgressView().controlSize(.small) } else { Label("Summarize", systemImage: "sparkles") }
            }
            .disabled(summarizing || lines.isEmpty)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(exportText(), forType: .string)
            } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
    }

    private var summary: some View {
        ScrollView {
            if let text = session?.summary, !text.isEmpty {
                MarkdownBlock(text: text).padding().textSelection(.enabled)
            } else {
                Text(LLMFactory.make(settings: settings) == nil
                     ? "Add an LLM API key in Settings → AI to get summaries."
                     : "No summary yet. It updates automatically while listening, or press Summarize.")
                    .foregroundStyle(.secondary).padding()
            }
        }
    }

    private var transcript: some View {
        List(lines) { line in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(line.startedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(line.speakerLabel).bold().foregroundStyle(SpeakerColor.color(for: line.speakerId))
                        if let app = line.appName { Text("· \(app)").foregroundStyle(.secondary) }
                    }
                    .font(.caption)
                    Text(line.text).textSelection(.enabled)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var speakerList: some View {
        List {
            Text("Rename a speaker to have Cabin recognise their voice by name in future sessions. If one person was split into two speakers, merge them.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(speakers) { entry in
                SpeakerRow(speaker: entry.speaker, ordinal: entry.ordinal,
                           others: speakers.filter { $0.speaker.id != entry.speaker.id && !$0.speaker.isUser })
            }
        }
    }

    private var termList: some View {
        List(terms) { term in
            VStack(alignment: .leading, spacing: 2) {
                Text(term.term).bold()
                Text(term.definition ?? "").foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func reload() {
        session = try? state.db.session(id: sessionId)
        if let session { title = session.displayTitle }
        lines = (try? state.db.transcript(sessionId: sessionId, userName: settings.myName)) ?? []
        speakers = (try? state.db.speakers(sessionId: sessionId)) ?? []
        terms = (try? state.db.terms(sessionId: sessionId)) ?? []
    }

    private func dateRange(_ s: SessionRecord) -> String {
        let start = s.startedAt.formatted(date: .complete, time: .shortened)
        guard let end = s.endedAt else { return "\(start) — in progress" }
        let minutes = Int(end.timeIntervalSince(s.startedAt) / 60)
        return "\(start) · \(minutes) min"
    }

    private func exportText() -> String {
        var out = "# \(title)\n\n"
        if let summary = session?.summary { out += summary + "\n\n## Transcript\n\n" }
        out += lines.map(Summarizer.format).joined(separator: "\n")
        return out
    }
}

private struct SpeakerRow: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    let speaker: SpeakerRecord
    let ordinal: Int
    let others: [SessionSpeaker]
    @State private var name = ""

    var body: some View {
        HStack {
            Circle().fill(SpeakerColor.color(for: speaker.id)).frame(width: 10, height: 10)
            Text(speaker.isUser ? "You" : "Speaker \(ordinal)")
                .foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            if speaker.isUser {
                Text(settings.myName.isEmpty ? "Me" : settings.myName)
                Text("(change in Settings)").font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
                Button("Save", action: save)
                if !others.isEmpty {
                    Menu("Merge into") {
                        ForEach(others) { other in
                            Button(SpeakerLabel.label(for: other.speaker, ordinal: other.ordinal, userName: settings.myName)) {
                                if let source = speaker.id, let target = other.speaker.id {
                                    state.mergeSpeaker(source, into: target)
                                }
                            }
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .onAppear { name = speaker.name ?? "" }
    }

    private func save() {
        guard let id = speaker.id else { return }
        state.renameSpeaker(id, to: name)
    }
}

struct GlossaryListView: View {
    @EnvironmentObject var state: AppState
    @State private var terms: [TermRecord] = []
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading) {
            TextField("Filter terms", text: $filter).textFieldStyle(.roundedBorder).padding([.horizontal, .top])
            List {
                ForEach(terms.filter { filter.isEmpty || $0.term.localizedCaseInsensitiveContains(filter) }) { term in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(term.term).bold()
                            Text(term.source == "wikipedia" ? "Wikipedia" : "inferred")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(term.definition ?? "").foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            if let id = term.id { try? state.db.deleteTerm(id: id); reload() }
                        }
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: state.dataVersion) { _, _ in reload() }
    }

    private func reload() { terms = (try? state.db.allDefinedTerms()) ?? [] }
}

/// Renders the small Markdown subset the summarizer produces (headings, bullets, checkboxes, inline styles).
struct MarkdownBlock: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                line(raw.trimmingCharacters(in: .whitespaces))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func line(_ s: String) -> some View {
        if s.hasPrefix("### ") {
            Text(inline(String(s.dropFirst(4)))).font(.headline)
        } else if s.hasPrefix("## ") || s.hasPrefix("# ") {
            Text(inline(s.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))).font(.title3.bold()).padding(.top, 6)
        } else if s.hasPrefix("- [ ] ") || s.hasPrefix("- [x] ") {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: s.hasPrefix("- [x] ") ? "checkmark.square" : "square")
                Text(inline(String(s.dropFirst(6))))
            }
        } else if s.hasPrefix("- ") || s.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline) {
                Text("•")
                Text(inline(String(s.dropFirst(2))))
            }
        } else if !s.isEmpty {
            Text(inline(s))
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
