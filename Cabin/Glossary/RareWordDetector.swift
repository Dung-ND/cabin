import Foundation

/// Finds words/acronyms that are NOT among the N most common words of a language.
/// Pure and deterministic, so it's unit-tested (see CabinTests).
final class RareWordDetector {
    private let ranks: [String: Int]   // lowercase word → frequency rank (0 = most common)
    var cutoff: Int

    /// Short all-caps tokens that are everyday enough to never explain.
    private static let commonAcronyms: Set<String> = [
        "OK", "TV", "US", "USA", "UK", "EU", "AM", "PM", "ID", "PC", "AI", "CEO", "FAQ", "PDF", "URL", "USB",
        "GPS", "DIY", "ASAP", "FYI", "BTW", "LOL", "OMG", "HR", "PR", "IT", "VS", "MR", "MRS", "DR", "ST",
    ]

    init(ranks: [String: Int], cutoff: Int) {
        self.ranks = ranks
        self.cutoff = cutoff
    }

    /// Loads `wordfreq-<lang>.txt` from the app bundle (one word per line, most common first).
    static func load(language: SupportedLanguage, cutoff: Int, bundle: Bundle = .main) -> RareWordDetector {
        var ranks: [String: Int] = [:]
        if let url = bundle.url(forResource: language.wordListResource, withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            var i = 0
            text.enumerateLines { line, _ in
                let w = line.trimmingCharacters(in: .whitespaces)
                if !w.isEmpty, ranks[w] == nil { ranks[w] = i }
                i += 1
            }
        }
        return RareWordDetector(ranks: ranks, cutoff: cutoff)
    }

    var isLoaded: Bool { !ranks.isEmpty }

    func isCommon(_ lower: String) -> Bool {
        for form in Self.baseForms(of: lower) {
            if let r = ranks[form], r < cutoff { return true }
        }
        return false
    }

    /// Candidate rare terms in `text`, in order of first appearance, de-duplicated (case-insensitive).
    func candidates(in text: String) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for token in Self.tokenize(text) {
            guard let term = classify(token) else { continue }
            let key = term.lowercased()
            if seen.insert(key).inserted { out.append(term) }
        }
        return out
    }

    private func classify(_ token: String) -> String? {
        var word = token.trimmingCharacters(in: CharacterSet(charactersIn: "-'’"))
        if word.hasSuffix("'s") || word.hasSuffix("’s") { word = String(word.dropLast(2)) }
        guard word.count >= 2, word.contains(where: \.isLetter) else { return nil }
        if word.allSatisfy({ $0.isNumber || $0 == "-" }) { return nil }

        // Acronyms like "RAG", "LLMs".
        let letters = word.filter(\.isLetter)
        let stem = word.dropLast()
        let isAllCaps = letters.count >= 2 && letters.allSatisfy(\.isUppercase)
        let isPluralAcronym = word.last == "s" && stem.filter(\.isLetter).count >= 2
            && stem.allSatisfy { $0.isUppercase || $0.isNumber }
        if isAllCaps || isPluralAcronym {
            let acronym = isPluralAcronym ? String(stem) : word
            guard acronym.count <= 8 else { return nil }          // long all-caps = emphasis, not jargon
            if Self.commonAcronyms.contains(acronym) { return nil }
            // "NO", "YES" etc. are just emphasised everyday words.
            if let r = ranks[acronym.lowercased()], r < 3_000 { return nil }
            return acronym
        }

        let lower = word.lowercased()
        guard lower.count >= 5 else { return nil }
        if isCommon(lower) { return nil }
        // Hyphenated compounds made of common parts ("well-known") are fine.
        if lower.contains("-"), lower.split(separator: "-").allSatisfy({ isCommon(String($0)) }) { return nil }
        // Keep proper-looking casing for capitalized tech terms ("Kubernetes"), lowercase otherwise.
        return word.first?.isUppercase == true ? word : lower
    }

    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "'" || ch == "’" {
                current.append(ch)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Cheap English inflection stripping so "deployments"/"deployed" count as "deploy".
    static func baseForms(of w: String) -> [String] {
        var forms = [w]
        func add(_ s: String) { if s.count >= 2 { forms.append(s) } }
        if w.hasSuffix("ies") { add(String(w.dropLast(3)) + "y") }
        if w.hasSuffix("es") { add(String(w.dropLast(2))) }
        if w.hasSuffix("s") { add(String(w.dropLast())) }
        if w.hasSuffix("ed") { add(String(w.dropLast(2))); add(String(w.dropLast(1))) }
        if w.hasSuffix("ing") { add(String(w.dropLast(3))); add(String(w.dropLast(3)) + "e") }
        if w.hasSuffix("ly") { add(String(w.dropLast(2))) }
        if w.hasSuffix("er") { add(String(w.dropLast(2))); add(String(w.dropLast(1))) }
        if w.hasSuffix("est") { add(String(w.dropLast(3))) }
        return forms
    }
}
