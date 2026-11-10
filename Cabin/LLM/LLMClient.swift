import Foundation

enum LLMError: LocalizedError {
    case notConfigured
    case missingKey(LLMProvider)
    case http(Int, String)
    case emptyResponse
    case badJSON(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No LLM provider is configured."
        case .missingKey(let p): return "Add your \(p.displayName) API key in Settings → AI."
        case .http(let code, let body): return "LLM request failed (\(code)): \(body.prefix(300))"
        case .emptyResponse: return "The LLM returned an empty response."
        case .badJSON(let text): return "The LLM returned invalid JSON: \(text.prefix(200))"
        }
    }
}

protocol LLMClient {
    /// Sends a system + user prompt; when `json` is true the model is asked to reply with a JSON object.
    func complete(system: String, user: String, json: Bool) async throws -> String
}

extension LLMClient {
    func completeJSON<T: Decodable>(_ type: T.Type, system: String, user: String) async throws -> T {
        let text = try await complete(system: system, user: user, json: true)
        let cleaned = Self.extractJSONObject(text)
        guard let data = cleaned.data(using: .utf8) else { throw LLMError.badJSON(text) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LLMError.badJSON(text)
        }
    }

    /// Tolerates models that wrap JSON in ``` fences or prose.
    static func extractJSONObject(_ text: String) -> String {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return text }
        return String(text[start...end])
    }
}

enum LLMFactory {
    /// Builds a client from current settings, or nil when no provider/key is set.
    static func make(settings: AppSettings = .shared) -> LLMClient? {
        let provider = settings.llmProvider
        guard provider != .none, let key = KeychainStore.read(provider.keychainAccount) else { return nil }
        switch provider {
        case .openAI:
            return OpenAIClient(apiKey: key, model: settings.openAIModel, baseURL: settings.openAIBaseURL)
        case .gemini:
            return GeminiClient(apiKey: key, model: settings.geminiModel)
        case .none:
            return nil
        }
    }
}

enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }()

    static func postJSON(_ url: URL, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.emptyResponse
        }
        return obj
    }
}
