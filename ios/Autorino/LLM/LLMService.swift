import Foundation

/// Replaces `llm_utils.py`'s model-name string-matching dispatch. The iOS
/// app ships Gemini only — no local/on-device model path (no Ollama, no
/// FoundationModels); see `docs/migration-architecture.md` §8.
///
/// Every call takes the model the caller picked (typically the
/// `geminiSelectedModel` `@AppStorage` value) and walks
/// `GeminiModelCatalog.fallbackModels` if that pick is unavailable — mirrors
/// `llm_utils.py`'s `_gemini_generate` fallback chain (llm_utils.py:150-176).
protocol LLMService {
    /// Mirrors `answer_to_prompt` (llm_utils.py:74).
    func answer(prompt: String, model: String) async throws -> String

    /// Mirrors `check_plausibility` (llm_utils.py:93) — same call, fixed prompt prefix.
    func checkPlausibility(text: String, model: String) async throws -> String

    /// Mirrors `chat_custom_prompt` (llm_utils.py:108): multi-turn, with
    /// `text` context injected into the new user turn only, and an optional
    /// system instruction built from `characters`. `modelUsed` differs from
    /// `model` only when the pick failed and a fallback answered instead.
    func chat(text: String, userPrompt: String, history: [ChatMessage], characters: [Character], model: String) async throws -> (message: ChatMessage, modelUsed: String)
}

enum LLMServiceError: LocalizedError {
    case missingAPIKey
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return String(localized: "No Gemini API key set. Add one in Settings.")
        case .requestFailed(let message): return message
        }
    }
}
