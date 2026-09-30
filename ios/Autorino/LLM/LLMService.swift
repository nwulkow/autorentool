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
    func answer(prompt: String, model: String, settings: GenerationSettings) async throws -> String

    /// Mirrors `check_plausibility` (llm_utils.py:93) — same call, fixed prompt prefix.
    func checkPlausibility(text: String, model: String, settings: GenerationSettings) async throws -> String

    /// Mirrors `chat_custom_prompt` (llm_utils.py:108): multi-turn, with
    /// `text` context injected into the new user turn only, and an optional
    /// system instruction built from `characters`. `modelUsed` differs from
    /// `model` only when the pick failed and a fallback answered instead.
    func chat(text: String, userPrompt: String, history: [ChatMessage], characters: [Character], model: String, settings: GenerationSettings) async throws -> (message: ChatMessage, modelUsed: String)

    /// Turns one chapter's prose into a `ChapterDigestPayload`. Constrained
    /// by a response schema rather than parsed out of free text, and run at
    /// `GenerationSettings.precise` — see the note there for why temperature
    /// is fixed rather than exposed.
    func digest(chapterTitle: String, chapterText: String, castNames: [String], model: String) async throws -> ChapterDigestPayload
}

/// How hard the model should think, and how freely it should sample.
///
/// Nothing was sent before this existed, so every call inherited Gemini's
/// *dynamic* thinking budget — reasonable for brainstorming, pure waste for
/// extraction, and the reason an idea prompt could sit for tens of seconds
/// with nothing on the wire. `nil` on either field omits the key entirely,
/// which reproduces that old behaviour exactly.
struct GenerationSettings: Hashable {
    var thinkingLevel: ThinkingLevel?
    var temperature: Double?

    enum ThinkingLevel: String, Hashable {
        case low, high
    }

    /// Whatever the model picks — identical on the wire to the pre-change code.
    static let auto = GenerationSettings(thinkingLevel: nil, temperature: nil)

    /// Idea generation: think hard, sample freely. 1.0 is Gemini's own default.
    static let creative = GenerationSettings(thinkingLevel: .high, temperature: 1.0)

    /// Pulling structure out of prose (chapter digests). Temperature is
    /// **fixed at 0 and deliberately not exposed in the UI**: extraction has
    /// one correct answer, a digest is cached and reused by every later
    /// prompt, and a sampled-at-random digest would quietly poison all of
    /// them. Reproducibility also means re-running on an unchanged chapter
    /// returns the same record, so a diff means the prose actually changed.
    static let precise = GenerationSettings(thinkingLevel: .low, temperature: 0.0)
}

/// The thinking choice as offered in the UI. Separate from
/// `GenerationSettings.ThinkingLevel` because the picker needs an explicit
/// "let the model decide" entry, which on the wire means *sending no
/// `thinkingConfig` at all* — and because a `String`-backed enum is what
/// `@AppStorage` can persist.
enum ThinkingSetting: String, CaseIterable, Hashable {
    case auto, low, high

    var level: GenerationSettings.ThinkingLevel? {
        switch self {
        case .auto: return nil
        case .low: return .low
        case .high: return .high
        }
    }

    /// Spelled out, for the menu items — where there is room and the word
    /// "thinking" is what makes the choice legible.
    ///
    /// Not a `Text` literal, so Xcode will not extract it — the catalog entry
    /// is maintained by hand (see the localization note in CLAUDE.md).
    var label: String {
        switch self {
        case .auto: return String(localized: "Thinking: auto")
        case .low: return String(localized: "Thinking: low")
        case .high: return String(localized: "Thinking: high")
        }
    }

    /// For the collapsed menu button, where the `brain` icon already carries
    /// the "thinking" half. The spelled-out German ("Denktiefe: automatisch")
    /// is ~130pt at `.caption`, and with the button `.fixedSize()` that eats
    /// the temperature slider's width on a 402pt phone — worse at larger
    /// Dynamic Type.
    var shortLabel: String {
        switch self {
        case .auto: return String(localized: "Auto")
        case .low: return String(localized: "Low")
        case .high: return String(localized: "High")
        }
    }
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
