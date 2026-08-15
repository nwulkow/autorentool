import Foundation

/// Mirrors the `{role, content}` shape `llm_utils.py`'s `chat_custom_prompt`
/// expects for `history` (llm_utils.py:108).
struct ChatMessage: Codable, Identifiable, Hashable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    var id: String = IDGenerator.uid()
    var role: Role
    var content: String
    var date: Date = Date()
}

/// Persisted per-book chat transcript (default `persist:true` behavior,
/// app.js's shared LLM pane). Feature-scoped panes that today use
/// `persist:false` (e.g. the event-order assistant) simply hold their
/// `[ChatMessage]` in view-local `@State` instead of going through this
/// store.
@MainActor
final class ChatHistoryStore: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []

    private let bookTitle: String
    private let fileManager = FileManager.default

    init(bookTitle: String) {
        self.bookTitle = bookTitle
        load()
    }

    private var fileURL: URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("ChatHistory", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("\(Book.sanitizedFilename(for: bookTitle))")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) else { return }
        messages = decoded
    }

    func append(_ message: ChatMessage) {
        messages.append(message)
        persist()
    }

    func clear() {
        messages = []
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
