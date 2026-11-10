import Foundation

/// OpenAI Chat Completions. `baseURL` can point at any OpenAI-compatible server
/// (e.g. Azure OpenAI proxy, OpenRouter, LM Studio, Ollama's /v1).
struct OpenAIClient: LLMClient {
    let apiKey: String
    let model: String
    let baseURL: String

    func complete(system: String, user: String, json: Bool) async throws -> String {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/chat/completions") else { throw LLMError.notConfigured }
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        let response = try await HTTP.postJSON(url, headers: ["Authorization": "Bearer \(apiKey)"], body: body)
        guard let choices = response["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty
        else { throw LLMError.emptyResponse }
        return content
    }
}
