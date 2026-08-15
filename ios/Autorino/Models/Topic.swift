import Foundation

/// Mirrors `topics` (app.js:71-75) — a post-it board with a list of URL
/// links, keyed by topic.
struct Topic: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var notes: [Note]
    var urlLinks: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, notes
        case urlLinks = "url_links"
    }

    init(id: String = IDGenerator.uid(), name: String = "", notes: [Note] = [], urlLinks: [String] = []) {
        self.id = id
        self.name = name
        self.notes = notes
        self.urlLinks = urlLinks
    }
}

/// A single post-it note (app.js:1412: `{id, text, color}`).
struct Note: Codable, Identifiable, Hashable {
    var id: String
    var text: String
    var color: String

    init(id: String = IDGenerator.uid(), text: String = "", color: String = "#fff9c4") {
        self.id = id
        self.text = text
        self.color = color
    }
}
