import Foundation

/// Which Gemini models the assistant offers, and what to try next when a pick
/// is unavailable. Mirrors `llm_utils.py`'s model-catalogue section
/// (`list_gemini_models`, `GEMINI_FALLBACK_MODELS`) so the same set of models
/// and the same "aliases first, then newest, stable before preview" ordering
/// show up on both apps — deliberately *not* shared code, since there's no
/// shared Swift/Python layer here, just the same rules re-implemented.
enum GeminiModelCatalog {
    static let defaultModel = "gemini-flash-latest"

    /// Tried in order when the picked model is unavailable. The moving
    /// aliases, not pinned versions — Google keeps them pointed at a live
    /// model, so this list can't itself go stale the way a pinned name would.
    static let fallbackModels = ["gemini-flash-latest", "gemini-pro-latest", "gemini-flash-lite-latest"]

    /// Used before the live list loads, and if the ListModels call fails
    /// (offline, bad key, quota) — so the picker always has something in it.
    static let staticModels = ["gemini-flash-latest", "gemini-pro-latest", "gemini-flash-lite-latest"]

    // Same non-chat families excluded server-side: image/audio generation,
    // robotics, embeddings, agentic research endpoints. Substring matching so
    // new members of a family are excluded on arrival.
    private static let excludedSubstrings = [
        "image", "banana", "tts", "audio", "omni", "live", "robotics",
        "computer-use", "deep-research", "antigravity", "embedding", "aqa",
        "veo", "imagen", "lyria", "customtools",
    ]

    /// Deprecated generations (2.5 and below) stay out of the picker. Aliases
    /// without a version number in the name (e.g. `gemini-flash-latest`) are
    /// always kept.
    private static let minVersion = 3.0

    private static var cache: (fetchedAt: Date, models: [String])?
    private static let cacheTTL: TimeInterval = 600

    private struct ListModelsResponse: Decodable {
        struct Model: Decodable {
            let name: String
            let supportedGenerationMethods: [String]?
        }
        let models: [Model]?
    }

    /// Text-capable Gemini models this API key can call, newest first.
    /// Cached in memory for `cacheTTL`; falls back to `staticModels` when
    /// there's no key or the call fails.
    static func fetchModels(apiKey: String?, force: Bool = false) async -> [String] {
        if !force, let cache, Date().timeIntervalSince(cache.fetchedAt) < cacheTTL {
            return cache.models
        }
        guard let apiKey, !apiKey.isEmpty else { return staticModels }
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "pageSize", value: "200"),
        ]
        do {
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return staticModels
            }
            let decoded = try JSONDecoder().decode(ListModelsResponse.self, from: data)
            let names = (decoded.models ?? [])
                .filter { ($0.supportedGenerationMethods ?? []).contains("generateContent") }
                .map { $0.name.replacingOccurrences(of: "models/", with: "") }
                .filter(isUsable)
            guard !names.isEmpty else { return staticModels }
            let sorted = names.sorted(by: sortsBefore)
            cache = (Date(), sorted)
            return sorted
        } catch {
            return staticModels
        }
    }

    private static func version(of name: String) -> Double? {
        guard let match = name.range(of: #"^gemini-(\d+(\.\d+)?)"#, options: .regularExpression) else { return nil }
        let numeric = name[match].dropFirst("gemini-".count)
        return Double(numeric)
    }

    private static func isUsable(_ name: String) -> Bool {
        guard name.hasPrefix("gemini-") else { return false }
        if excludedSubstrings.contains(where: name.contains) { return false }
        guard let version = version(of: name) else { return true }
        return version >= minVersion
    }

    /// Aliases first (they always resolve), then newest version, stable
    /// before preview, then alphabetically.
    private static func sortsBefore(_ a: String, _ b: String) -> Bool {
        let va = version(of: a), vb = version(of: b)
        if (va == nil) != (vb == nil) { return va == nil }
        if va != vb { return (va ?? 0) > (vb ?? 0) }
        let pa = a.contains("preview"), pb = b.contains("preview")
        if pa != pb { return !pa }
        return a < b
    }
}
