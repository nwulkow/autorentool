import Foundation

/// Mirrors the `{role, content}` shape `llm_utils.py`'s `chat_custom_prompt`
/// expects for `history` (llm_utils.py:108).
///
/// Coding is written out by hand rather than synthesized because a
/// `ChatMessage` is now persisted through *two* different encoders: the chat
/// transcript files (`ChatHistoryStore`/`ChatHistorySyncEngine`) and, since
/// saved chats, inside a book document via `BookStore`'s plain `JSONEncoder`.
/// `date` therefore encodes as an explicit ISO-8601 **string** here instead of
/// relying on the encoder's `dateEncodingStrategy` — that's the format
/// `server.py`'s `_llm_chat` writes (`datetime.now(timezone.utc).isoformat()`)
/// into the same synced files, and a numeric timestamp from a default-strategy
/// encoder would be unreadable to it (and to us on the way back). Decoding
/// accepts a numeric timestamp too, so any file already written that way still
/// loads.
struct ChatMessage: Codable, Identifiable, Hashable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    var id: String = IDGenerator.uid()
    var role: Role
    var content: String
    var date: Date = Date()
    /// `false` marks a reply produced *without* the selected chapter/passage
    /// text in its prompt — the "Include book text" switch was off for that
    /// turn. Surfaced as a tag on the bubble so a transcript read back later
    /// still says which answers weren't grounded in the manuscript. `nil`
    /// means "written before this flag existed" and reads as "included".
    var usedBookText: Bool?

    enum CodingKeys: String, CodingKey {
        case id, role, content, date
        case usedBookText = "used_book_text"
    }

    init(id: String = IDGenerator.uid(), role: Role, content: String, date: Date = Date(), usedBookText: Bool? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.date = date
        self.usedBookText = usedBookText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? IDGenerator.uid()
        role = (try? c.decode(Role.self, forKey: .role)) ?? .assistant
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        if let raw = try? c.decode(String.self, forKey: .date) {
            date = ISODate.date(from: raw) ?? Date()
        } else if let epoch = try? c.decode(Double.self, forKey: .date) {
            date = Date(timeIntervalSinceReferenceDate: epoch)
        } else {
            date = Date()
        }
        usedBookText = try c.decodeIfPresent(Bool.self, forKey: .usedBookText)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        try c.encode(ISODate.string(from: date), forKey: .date)
        // Only when actually set, so a transcript written before this flag
        // existed round-trips byte-identical instead of gaining a `null`.
        try c.encodeIfPresent(usedBookText, forKey: .usedBookText)
    }
}

/// The one ISO-8601 spelling shared by every date this app writes into a file
/// the Mac app also reads. `withFractionalSeconds` matches Python's
/// microsecond-precision `isoformat()`; the plain-seconds parse covers dates
/// written by anything that omits them.
enum ISODate {
    static func string(from date: Date) -> String { withFractional.string(from: date) }

    static func date(from raw: String) -> Date? {
        withFractional.date(from: raw) ?? plain.date(from: raw)
    }

    private static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

extension ChatMessage {
    /// Shared coder pair for every place that reads/writes a chat transcript
    /// file (`ChatHistoryStore` and `ChatHistorySyncEngine`). Plain coders:
    /// `date` is handled by `ChatMessage`'s own `encode(to:)`/`init(from:)`
    /// (see the type doc), so no `dateEncodingStrategy` is needed — and
    /// crucially, none is *required*, which is what lets a `ChatMessage` also
    /// ride along inside a `Book` through `BookStore`'s default encoder.
    static let decoder = JSONDecoder()
    static let encoder = JSONEncoder()
}

/// An on-demand snapshot of a conversation, stored on the book so it syncs,
/// renames and deletes with the book itself rather than needing its own
/// Dropbox folder and index.
///
/// `chapterNumber`/`chapterLabel` are copied in at save time and never
/// recomputed: the point of saving a chat is to keep a record of a discussion
/// about the chapter *as it stood then*, so later reordering or retitling
/// must not rewrite what the saved chat says it was about.
struct SavedChat: Codable, Identifiable, Hashable {
    var id: String = IDGenerator.uid()
    var name: String
    var savedAt: Date = Date()
    /// 1-based position of the chapter the chat was anchored to, `nil` for a
    /// chat saved outside a chapter (e.g. the event-order assistant).
    var chapterNumber: Int?
    var chapterLabel: String
    var messages: [ChatMessage]

    enum CodingKeys: String, CodingKey {
        case id, name
        case savedAt = "saved_at"
        case chapterNumber = "chapter_number"
        case chapterLabel = "chapter_label"
        case messages
    }

    init(id: String = IDGenerator.uid(), name: String, savedAt: Date = Date(), chapterNumber: Int? = nil, chapterLabel: String = "", messages: [ChatMessage] = []) {
        self.id = id
        self.name = name
        self.savedAt = savedAt
        self.chapterNumber = chapterNumber
        self.chapterLabel = chapterLabel
        self.messages = messages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? IDGenerator.uid()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        savedAt = (try? c.decode(String.self, forKey: .savedAt)).flatMap(ISODate.date(from:)) ?? Date()
        chapterNumber = try c.decodeIfPresent(Int.self, forKey: .chapterNumber)
        chapterLabel = try c.decodeIfPresent(String.self, forKey: .chapterLabel) ?? ""
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(ISODate.string(from: savedAt), forKey: .savedAt)
        try c.encode(chapterNumber, forKey: .chapterNumber) // explicit null, matching serializeBook
        try c.encode(chapterLabel, forKey: .chapterLabel)
        try c.encode(messages, forKey: .messages)
    }

    /// "3 – The Fall", "3", or "" — what the list row shows under the name.
    var chapterDescription: String {
        switch (chapterNumber, chapterLabel.isEmpty) {
        case (let n?, false): return "\(n) – \(chapterLabel)"
        case (let n?, true): return "\(n)"
        case (nil, false): return chapterLabel
        case (nil, true): return ""
        }
    }
}

/// Persisted per-book chat transcript (default `persist:true` behavior,
/// app.js's shared LLM pane). Feature-scoped panes that today use
/// `persist:false` (e.g. the event-order assistant) simply hold their
/// `[ChatMessage]` in view-local `@State` instead of going through this
/// store.
///
/// Lives under `Documents/ChatHistory/`, a sibling of `BookStore`'s
/// `Documents/Books/` — not `Application Support` — specifically so
/// `ChatHistorySyncEngine` can push/pull it through the same Dropbox App
/// folder as books, just under its own subpath. Local-only storage
/// (the previous behavior) didn't survive a reinstall or show up on a
/// second device; Dropbox is this app's existing answer to both.
@MainActor
final class ChatHistoryStore: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []

    let filename: String
    private let fileManager = FileManager.default
    /// Set by the owning view once `AppEnvironment` is available (not yet at
    /// `init` time — this is usually built as a `@StateObject`, before
    /// `@EnvironmentObject` resolves). `nil` just means "sync will pick this
    /// file up on its next full pass anyway, only slightly later."
    var onChange: ((String) -> Void)?

    init(bookTitle: String) {
        self.filename = Book.sanitizedFilename(for: bookTitle)
        load()
    }

    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("ChatHistory", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var fileURL: URL { Self.directory.appendingPathComponent(filename) }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? ChatMessage.decoder.decode([ChatMessage].self, from: data) else { return }
        messages = decoded
    }

    /// Re-reads from disk — called after `ChatHistorySyncEngine` pulls a
    /// remote copy down, the same way `BookStore.reload()` picks up a
    /// synced book.
    func reload() { load() }

    func append(_ message: ChatMessage) {
        messages.append(message)
        persist()
    }

    /// Swaps the whole transcript out — how "Load chat" resumes a saved
    /// conversation: the loaded turns become the live history, so the next
    /// prompt continues from them.
    func replace(with messages: [ChatMessage]) {
        self.messages = messages
        persist()
    }

    func clear() {
        messages = []
        persist()
    }

    private func persist() {
        guard let data = try? ChatMessage.encoder.encode(messages) else { return }
        try? data.write(to: fileURL, options: .atomic)
        onChange?(filename)
    }
}
