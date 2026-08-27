import Foundation

/// Direct `URLSession` calls to the Gemini REST API — the same call shapes as
/// `llm_utils.py` (llm_utils.py:74-139), just called straight from the client
/// instead of proxied through `server.py` (no API key exposure risk on a
/// device the user owns; the key lives in the Keychain, entered in Settings).
/// Model selection and fallback mirror `llm_utils.py`'s `_gemini_generate`
/// (llm_utils.py:150-176) — see `GeminiModelCatalog`.
struct GeminiLLMService: LLMService {
    private static let requestTimeout: TimeInterval = 20

    private var apiKey: String? { KeychainService.get(.geminiAPIKey) }

    func answer(prompt: String, model: String) async throws -> String {
        try await generateContent(contents: [.init(role: "user", text: prompt)], systemInstruction: nil, model: model).text
    }

    func checkPlausibility(text: String, model: String) async throws -> String {
        // Mirrors check_plausibility's fixed prompt prefix (llm_utils.py:95).
        try await answer(prompt: "Check whether the following text is plausible (answer in the language the text is written in):\n\n" + text, model: model)
    }

    func chat(text: String, userPrompt: String, history: [ChatMessage], characters: [Character], model: String) async throws -> (message: ChatMessage, modelUsed: String) {
        let systemText = PromptBuilder.characterSystemInstruction(characters)
        let newUserContent = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? userPrompt
            : "\(userPrompt)\n\n[Text context]\n\(text)"

        var contents = history.map { GeminiContent(role: $0.role == .user ? "user" : "model", text: $0.content) }
        contents.append(GeminiContent(role: "user", text: newUserContent))

        let result = try await generateContent(contents: contents, systemInstruction: systemText, model: model)
        return (ChatMessage(role: .assistant, content: result.text), result.model)
    }

    /// Runs one generateContent call, walking `model` then
    /// `GeminiModelCatalog.fallbackModels` until one answers. Returns the text
    /// plus which model actually produced it, so callers can tell the user
    /// their pick was substituted.
    private func generateContent(contents: [GeminiContent], systemInstruction: String?, model: String) async throws -> (text: String, model: String) {
        guard let apiKey, !apiKey.isEmpty else { throw LLMServiceError.missingAPIKey }

        var chain = [model] + GeminiModelCatalog.fallbackModels
        var seen = Set<String>()
        chain = chain.filter { seen.insert($0).inserted }

        var lastError: Error = LLMServiceError.requestFailed("No Gemini model answered.")
        for candidate in chain {
            do {
                let text = try await callGenerateContent(contents: contents, systemInstruction: systemInstruction, model: candidate, apiKey: apiKey)
                return (text, candidate)
            } catch {
                lastError = error
                guard isRetryable(error) else { throw error }
            }
        }
        throw lastError
    }

    private func callGenerateContent(contents: [GeminiContent], systemInstruction: String?, model: String, apiKey: String) async throws -> String {
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A model that's genuinely unavailable should fail fast enough to
        // leave time for the rest of the fallback chain, rather than eating
        // `URLSession`'s much longer default timeout on every attempt.
        request.timeoutInterval = Self.requestTimeout

        var body: [String: Any] = [
            "contents": contents.map { ["role": $0.role, "parts": [["text": $0.text]]] },
        ]
        if let systemInstruction, !systemInstruction.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemInstruction]]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMServiceError.requestFailed("Gemini request failed")
        }
        guard 200..<300 ~= http.statusCode else {
            let message = (try? JSONDecoder().decode(GeminiErrorResponse.self, from: data).error.message)
                ?? String(data: data, encoding: .utf8) ?? "Gemini request failed"
            throw GeminiHTTPError(statusCode: http.statusCode, message: message)
        }
        let decoded = try JSONDecoder().decode(GeminiGenerateResponse.self, from: data)
        guard let text = decoded.candidates?.first?.content?.parts?.first?.text else {
            throw LLMServiceError.requestFailed("Gemini returned no text.")
        }
        return text
    }

    /// True for "this model isn't answering right now" — unknown/retired
    /// model (404), quota (429), overloaded/outage (5xx), or a network drop.
    /// A bad API key (401/403) isn't retryable: every fallback would fail the
    /// same way, so failing fast beats several timeouts in a row.
    private func isRetryable(_ error: Error) -> Bool {
        if let httpError = error as? GeminiHTTPError {
            return httpError.statusCode == 404 || httpError.statusCode == 408
                || httpError.statusCode == 409 || httpError.statusCode == 429
                || httpError.statusCode >= 500
        }
        return error is URLError
    }
}

private struct GeminiHTTPError: Error {
    let statusCode: Int
    let message: String
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
