import Foundation

struct WikiSummary {
    let title: String
    let extract: String
    let url: String?
}

/// Free, key-less definitions from Wikipedia's REST summary endpoint.
enum WikipediaLookup {
    static func summary(for term: String, host: String) async -> WikiSummary? {
        let title = term.replacingOccurrences(of: " ", with: "_")
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://\(host)/api/rest_v1/page/summary/\(encoded)?redirect=true")
        else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.setValue("Cabin/0.1 (macOS desktop app)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await HTTP.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) != "disambiguation",
              let extract = obj["extract"] as? String, !extract.isEmpty
        else { return nil }
        let page = ((obj["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String
        return WikiSummary(title: obj["title"] as? String ?? term, extract: extract, url: page)
    }

    static func firstSentences(_ text: String, maxLength: Int = 260) -> String {
        if text.count <= maxLength { return text }
        let cut = text.prefix(maxLength)
        if let dot = cut.lastIndex(of: ".") { return String(cut[...dot]) }
        return cut + "…"
    }
}
