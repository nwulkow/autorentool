import Foundation

/// Direct `URLSession` calls to the Gemini REST API — the same
/// `gemini-flash-latest` model and call shapes as `llm_utils.py`
/// (llm_utils.py:74-139), just called straight from the client instead of
/// proxied through `server.py` (no API key exposure risk on a device the
/// user owns; the key lives in the Keychain, entered in Settings).
struct GeminiLLMService: LLMService {
    private let model = "gemini-flash-latest"

    private var apiKey: String? { KeychainService.get(.geminiAPIKey) }

    func answer(prompt: String) async throws -> String {
        try await generateContent(contents: [.init(role: "user", text: prompt)], systemInstruction: nil)
    }

    func checkPlausibility(text: String) async throws -> String {
        // Mirrors check_plausibility's fixed prompt prefix (llm_utils.py:95).
        try await answer(prompt: "Check whether the following text is plausible (answer in the language the text is written in):\n\n" + text)
    }

    func chat(text: String, userPrompt: String, history: [ChatMessage], characters: [Character]) async throws -> ChatMessage {
        let systemText = PromptBuilder.characterSystemInstruction(characters)
        let newUserContent = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? userPrompt
            : "\(userPrompt)\n\n[Text context]\n\(text)"

        var contents = history.map { GeminiContent(role: $0.role == .user ? "user" : "model", text: $0.content) }
        contents.append(GeminiContent(role: "user", text: newUserContent))

        let replyText = try await generateContent(contents: contents, systemInstruction: systemText)
        return ChatMessage(role: .assistant, content: replyText)
    }

    private func generateContent(contents: [GeminiContent], systemInstruction: String?) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else { throw LLMServiceError.missingAPIKey }
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "contents": contents.map { ["role": $0.role, "parts": [["text": $0.text]]] },
        ]
        if let systemInstruction, !systemInstruction.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemInstruction]]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let message = (try? JSONDecoder().decode(GeminiErrorResponse.self, from: data).error.message)
                ?? String(data: data, encoding: .utf8) ?? "Gemini request failed"
            throw LLMServiceError.requestFailed(message)
        }
        let decoded = try JSONDecoder().decode(GeminiGenerateResponse.self, from: data)
        guard let text = decoded.candidates?.first?.content?.parts?.first?.text else {
            throw LLMServiceError.requestFailed("Gemini returned no text.")
        }
        return text
    }
}

private struct GeminiContent {
    var role: String
    var text: String
}

private struct GeminiGenerateResponse: Codable {
    struct Candidate: Codable {
        struct Content: Codable {
            struct Part: Codable { let text: String? }
            let parts: [Part]?
        }
        let content: Content?
    }
    let candidates: [Candidate]?
}

private struct GeminiErrorResponse: Codable {
    struct ErrorBody: Codable { let message: String }
    let error: ErrorBody
}
