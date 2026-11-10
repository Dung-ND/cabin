import Foundation

/// Google Gemini via the Generative Language API (API key from Google AI Studio).
struct GeminiClient: LLMClient {
    let apiKey: String
    let model: String

    func complete(system: String, user: String, json: Bool) async throws -> String {
        let name = model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(name):generateContent") else {
            throw LLMError.notConfigured
        }
        var generationConfig: [String: Any] = [:]
        if json { generationConfig["responseMimeType"] = "application/json" }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": generationConfig,
        ]
        let response = try await HTTP.postJSON(url, headers: ["x-goog-api-key": apiKey], body: body)
        guard let candidates = response["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else { throw LLMError.emptyResponse }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw LLMError.emptyResponse }
        return text
    }
}
