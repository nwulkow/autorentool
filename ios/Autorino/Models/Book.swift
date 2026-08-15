import Foundation

/// The top-level book document. Field set and snake_case keys mirror
/// `serializeBook`/`deserializeBook` exactly (app.js:45-113) so a file
/// written by this app round-trips through the Mac app unchanged, and
/// vice versa — this identity is what makes Dropbox sync a plain file
/// sync rather than a format-translating one.
///
/// There is no persisted `id` field (books are identified by their
/// filename/title on disk, same as `server.py`'s `_save_book`). `id` here
/// is a local-only SwiftUI convenience derived from the title.
struct Book: Codable, Hashable {
    var title: String
    var author: String
    var tags: [String]
    var chapters: [Chapter]
    var passages: [Passage]
    var characters: [Character]
    var characterRelations: [CharacterRelation]
    var canvasNodes: [CanvasNode]
    var questions: [Question]
    var eventOrders: [EventOrder]
    var locations: [Location]
    var topics: [Topic]

    enum CodingKeys: String, CodingKey {
        case title, author, tags, chapters, passages, characters
        case characterRelations = "character_relations"
        case canvasNodes = "canvas_nodes"
        case questions
        case eventOrders = "event_orders"
        case locations, topics
    }

    init(
        title: String,
        author: String = "",
        tags: [String] = [],
        chapters: [Chapter] = [],
        passages: [Passage] = [],
        characters: [Character] = [],
        characterRelations: [CharacterRelation] = [],
        canvasNodes: [CanvasNode] = [],
        questions: [Question] = [],
        eventOrders: [EventOrder] = [],
        locations: [Location] = [],
        topics: [Topic] = []
    ) {
        self.title = title
        self.author = author
        self.tags = tags
        self.chapters = chapters
        self.passages = passages
        self.characters = characters
        self.characterRelations = characterRelations
        self.canvasNodes = canvasNodes
        self.questions = questions
        self.eventOrders = eventOrders
        self.locations = locations
        self.topics = topics
    }

    /// Decodes leniently like `deserializeBook`: every collection defaults
    /// to `[]` and every id defaults to a fresh `uid()` when absent, so
    /// hand-edited or older JSON files still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        chapters = try c.decodeIfPresent([Chapter].self, forKey: .chapters) ?? []
        passages = try c.decodeIfPresent([Passage].self, forKey: .passages) ?? []
        characters = try c.decodeIfPresent([Character].self, forKey: .characters) ?? []
        characterRelations = try c.decodeIfPresent([CharacterRelation].self, forKey: .characterRelations) ?? []
        canvasNodes = try c.decodeIfPresent([CanvasNode].self, forKey: .canvasNodes) ?? []
        questions = try c.decodeIfPresent([Question].self, forKey: .questions) ?? []
        eventOrders = try c.decodeIfPresent([EventOrder].self, forKey: .eventOrders) ?? []
        locations = try c.decodeIfPresent([Location].self, forKey: .locations) ?? []
        topics = try c.decodeIfPresent([Topic].self, forKey: .topics) ?? []
    }
}

extension Book: Identifiable {
    var id: String { title }
}

extension Book {
    /// Mirrors `server.py`'s `_save_book` sanitization exactly (server.py:150-152):
    /// keep letters, digits, space, `-`, `_`; replace everything else with
    /// `_`; then strip leading/trailing whitespace. Must match byte-for-byte,
    /// or Dropbox sync won't line up local and remote copies of the same
    /// book by filename.
    static func sanitizedFilename(for title: String) -> String {
        let allowed = CharacterSet(charactersIn: " -_").union(.alphanumerics)
        let sanitized = title.unicodeScalars.map { allowed.contains($0) ? Swift.Character($0) : "_" }
        let safe = String(sanitized).trimmingCharacters(in: .whitespaces)
        return safe + ".json"
    }

    var filename: String { Book.sanitizedFilename(for: title) }
}
