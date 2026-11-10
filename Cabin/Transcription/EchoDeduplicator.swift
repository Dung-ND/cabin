import Foundation

/// When you're not on headphones, the mic hears what your speakers play. This drops microphone
/// lines that closely match system-audio lines from the same moment, so remote voices aren't
/// attributed to you.
struct EchoDeduplicator {
    struct Entry {
        let id: Int64
        let source: AudioSourceKind
        let start: Date
        let end: Date
        let words: Set<String>
    }

    var window: TimeInterval = 6
    var similarity: Double = 0.55
    private(set) var recent: [Entry] = []

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 })
    }

    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }

    /// Returns the ids of entries that are echoes given the new line:
    /// - a new mic line that matches recent system audio → [newId] (the new line is the echo)
    /// - a new system line that matches recent mic lines → those mic ids
    mutating func add(id: Int64, source: AudioSourceKind, start: Date, end: Date, text: String) -> [Int64] {
        let entry = Entry(id: id, source: source, start: start, end: end, words: Self.words(text))
        recent.removeAll { $0.end < start.addingTimeInterval(-window * 3) }
        let nearby = recent.filter {
            $0.source != source && $0.start <= end.addingTimeInterval(window) && $0.end >= start.addingTimeInterval(-window)
        }
        var echoes: [Int64] = []
        let matches = nearby.filter { Self.overlap($0.words, entry.words) >= similarity && entry.words.count >= 3 }
        if !matches.isEmpty {
            if source == .microphone {
                echoes = [id]
                return echoes        // don't remember the echo
            } else {
                echoes = matches.map(\.id)
                recent.removeAll { echoes.contains($0.id) }
            }
        }
        recent.append(entry)
        return echoes
    }
}
