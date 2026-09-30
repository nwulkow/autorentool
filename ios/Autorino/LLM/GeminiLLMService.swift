import Foundation

/// Direct `URLSession` calls to the Gemini REST API — the same call shapes as
/// `llm_utils.py` (llm_utils.py:74-139), just called straight from the client
/// instead of proxied through `server.py` (no API key exposure risk on a
/// device the user owns; the key lives in the Keychain, entered in Settings).
/// Model selection and fallback mirror `llm_utils.py`'s `_gemini_generate`
/// (llm_utils.py:150-176) — see `GeminiModelCatalog`.
struct GeminiLLMService: LLMService {
    /// Generous on purpose. The Gemini 3.x models think before they answer,
    /// and none of that shows up as bytes on the wire — a chapter-sized
    /// prompt to `gemini-3.8-flash` measured 17–26s wall clock, spending
    /// 2000–3000 thinking tokens before emitting its first text token. The
    /// old 20s ceiling cut those off mid-flight, which is what made the
    /// assistant look like it "often gives no response": the request was
    /// killed, classified retryable, and the whole fallback chain then
    /// burned another 20s per model before surfacing an error.
    private static let requestTimeout: TimeInterval = 120

    /// Fallbacks exist to route around a model that is retired, out of quota
    /// or overloaded — all of which come back as an HTTP error in well under
    /// a second. None of them needs the primary's budget, so a fallback that
    /// goes quiet is almost certainly going quiet for the same reason the
    /// primary did, and waiting two more minutes for it tells us nothing.
    private static let fallbackTimeout: TimeInterval = 30

    /// Hard ceiling on one `generateContent` call including every fallback,
    /// checked before each additional attempt. Belt to `isRetryable`'s
    /// braces: even if some future error type is misclassified as retryable,
    /// the chain cannot run away into the multi-minute territory it used to.
    private static let totalBudget: TimeInterval = 180

    private var apiKey: String? { KeychainService.get(.geminiAPIKey) }

    func answer(prompt: String, model: String, settings: GenerationSettings) async throws -> String {
        try await generateContent(contents: [.init(role: "user", text: prompt)], systemInstruction: nil, model: model, settings: settings).text
    }

    func checkPlausibility(text: String, model: String, settings: GenerationSettings) async throws -> String {
        // Mirrors check_plausibility's fixed prompt prefix (llm_utils.py:95).
        try await answer(prompt: "Check whether the following text is plausible (answer in the language the text is written in):\n\n" + text, model: model, settings: settings)
    }

    func chat(text: String, userPrompt: String, history: [ChatMessage], characters: [Character], model: String, settings: GenerationSettings) async throws -> (message: ChatMessage, modelUsed: String) {
        let systemText = PromptBuilder.characterSystemInstruction(characters)
        let newUserContent = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? userPrompt
            : "\(userPrompt)\n\n[Text context]\n\(text)"

        var contents = history.map { GeminiContent(role: $0.role == .user ? "user" : "model", text: $0.content) }
        contents.append(GeminiContent(role: "user", text: newUserContent))

        let result = try await generateContent(contents: contents, systemInstruction: systemText, model: model, settings: settings)
        return (ChatMessage(role: .assistant, content: result.text), result.model)
    }

    func digest(chapterTitle: String, chapterText: String, castNames: [String], model: String) async throws -> ChapterDigestPayload {
        let cast = castNames.isEmpty ? "(none recorded yet)" : castNames.joined(separator: ", ")
        let instruction = """
        You extract structure from one chapter of a novel. Invent nothing: record only what the text
        states or strictly implies. If a field has nothing in it, return an empty list or an empty
        string rather than guessing.

        Write every value in the language the chapter is written in.

        Known characters — use EXACTLY these names in `pov`, `present` and `learns.who`:
        \(cast)
        Any other person named in the text goes in `unknownNames` instead, spelled as the text
        spells it.

        summary: about 120 words, causal — why things happen, not only what happens.

        learns: every piece of information a character NEWLY acquires in this chapter, and how it
        reached them (seen, overheard, a document, an admission, research, inference). Set certainty
        to "confirmed" when the chapter establishes it as fact for that character, and "suspected"
        when they infer, guess, or doubt it. The difference between knowing and suspecting is
        usually the plot, so do not round one to the other.

        established: facts that are fixed from this chapter onwards.

        devices: the means the chapter uses to move information (a newspaper article, a photograph,
        a manipulated record), so later chapters can avoid repeating them.

        open: what the chapter deliberately leaves unresolved.
        """
        let prompt = "--- \(chapterTitle) ---\n\(chapterText)"
        let result = try await generateContent(
            contents: [.init(role: "user", text: prompt)],
            systemInstruction: instruction,
            model: model,
            settings: .precise,
            responseSchema: ChapterDigestPayload.geminiSchema
        )
        guard let data = result.text.data(using: .utf8) else {
            throw LLMServiceError.requestFailed(String(localized: "The digest came back unreadable."))
        }
        return try JSONDecoder().decode(ChapterDigestPayload.self, from: data)
    }

    /// Runs one generateContent call, walking `model` then
    /// `GeminiModelCatalog.fallbackModels` until one answers. Returns the text
    /// plus which model actually produced it, so callers can tell the user
    /// their pick was substituted.
    private func generateContent(contents: [GeminiContent], systemInstruction: String?, model: String, settings: GenerationSettings, responseSchema: [String: Any]? = nil) async throws -> (text: String, model: String) {
        guard let apiKey, !apiKey.isEmpty else { throw LLMServiceError.missingAPIKey }

        var chain = [model] + GeminiModelCatalog.fallbackModels
        var seen = Set<String>()
        chain = chain.filter { seen.insert($0).inserted }

        let deadline = Date().addingTimeInterval(Self.totalBudget)
        var lastError: Error = LLMServiceError.requestFailed("No Gemini model answered.")
        for (attempt, candidate) in chain.enumerated() {
            // Never truncate the first attempt — it is the model the user
            // actually picked, and it owns the whole `requestTimeout`.
            if attempt > 0, Date() >= deadline { break }
            do {
                let text = try await callGenerateContent(
                    contents: contents,
                    systemInstruction: systemInstruction,
                    model: candidate,
                    apiKey: apiKey,
                    settings: settings,
                    responseSchema: responseSchema,
                    timeout: attempt == 0 ? Self.requestTimeout : Self.fallbackTimeout
                )
                return (text, candidate)
            } catch {
                lastError = error
                guard isRetryable(error) else { throw error }
            }
        }
        throw lastError
    }

    private func callGenerateContent(contents: [GeminiContent], systemInstruction: String?, model: String, apiKey: String, settings: GenerationSettings, responseSchema: [String: Any]?, timeout: TimeInterval) async throws -> String {
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A model that's genuinely unavailable should fail fast enough to
        // leave time for the rest of the fallback chain, rather than eating
        // `URLSession`'s much longer default timeout on every attempt.
        request.timeoutInterval = timeout

        var body: [String: Any] = [
            "contents": contents.map { ["role": $0.role, "parts": [["text": $0.text]]] },
        ]
        if let systemInstruction, !systemInstruction.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemInstruction]]]
        }
        // Built conditionally, and omitted entirely when empty, so
        // `GenerationSettings.auto` puts exactly the same bytes on the wire as
        // the code that had no settings at all. `maxOutputTokens` is
        // deliberately *not* set: thinking tokens count against it, so a cap
        // here makes the `MAX_TOKENS` failure below more frequent rather than
        // less. Answer length belongs in the prompt.
        var generationConfig: [String: Any] = [:]
        if let temperature = settings.temperature {
            generationConfig["temperature"] = temperature
        }
        if let thinkingLevel = settings.thinkingLevel {
            generationConfig["thinkingConfig"] = ["thinkingLevel": thinkingLevel.rawValue]
        }
        // Constrained decoding. Without it the model wraps its JSON in prose
        // or a ```json fence often enough that extraction needs a repair
        // pass; with it the body is the object and nothing else.
        if let responseSchema {
            generationConfig["responseMimeType"] = "application/json"
            generationConfig["responseSchema"] = responseSchema
        }
        if !generationConfig.isEmpty {
            body["generationConfig"] = generationConfig
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
        let candidate = decoded.candidates?.first
        // A thinking model can return parts that are *all* thought — or none
        // at all — so take the first part that actually carries text rather
        // than assuming `parts[0]` is the answer.
        let text = candidate?.content?.parts?
            .compactMap(\.text)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let text { return text }

        // No text came back. Say *why*, so a retry is an informed choice
        // rather than a guess — these are the cases the user actually hits.
        switch candidate?.finishReason {
        case "MAX_TOKENS":
            throw LLMServiceError.requestFailed(
                String(localized: "The model used its whole budget thinking and ran out before writing an answer. Try again, or send less text.")
            )
        case "SAFETY", "PROHIBITED_CONTENT":
            throw LLMServiceError.requestFailed(
                String(localized: "The model declined to answer about this passage.")
            )
        case "RECITATION":
            throw LLMServiceError.requestFailed(
                String(localized: "The model stopped because its answer was reproducing existing text.")
            )
        default:
            throw LLMServiceError.requestFailed(String(localized: "Gemini returned no text."))
        }
    }

    /// True for "this model isn't answering right now" — unknown/retired
    /// model (404), quota (429), overloaded/outage (5xx), or a network drop.
    /// A bad API key (401/403) isn't retryable: every fallback would fail the
    /// same way, so failing fast beats several timeouts in a row.
    ///
    /// Two `URLError`s are deliberately *not* retryable:
    ///
    /// - `.timedOut` — a timeout says this *prompt* was slow, not that the
    ///   model is down. The next candidate gets the identical prompt and
    ///   stalls the identical way, so falling back re-pays the full wait once
    ///   per model. With a 120s ceiling and a four-name chain that turned one
    ///   slow request into an eight-minute wait ending in an error, which is
    ///   what "the assistant takes several minutes" actually was.
    /// - `.cancelled` — the user dismissed the sheet or hit stop. Firing three
    ///   more requests on their way out is the opposite of what they asked for.
    private func isRetryable(_ error: Error) -> Bool {
        if let httpError = error as? GeminiHTTPError {
            return httpError.statusCode == 404 || httpError.statusCode == 408
                || httpError.statusCode == 409 || httpError.statusCode == 429
                || httpError.statusCode >= 500
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cancelled: return false
            default: return true
            }
        }
        // Anything else (a decode failure, say) is a bug in us or a change in
        // the response shape. Retrying three more models hides it.
        return false
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
        let finishReason: String?
    }
    let candidates: [Candidate]?
}

private struct GeminiErrorResponse: Codable {
    struct ErrorBody: Codable { let message: String }
    let error: ErrorBody
}
