import Foundation

/// Mirrors `serializeBook`'s `characters` shape (app.js:54) and
/// `classes.py`'s `Character`.
struct Character: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var description: String
    var tags: [String]

    init(id: String = IDGenerator.uid(), name: String = "", description: String = "", tags: [String] = []) {
        self.id = id
        self.name = name
        self.description = description
        self.tags = tags
    }
}

/// Mirrors `character_relations` (app.js:55-57).
struct CharacterRelation: Codable, Identifiable, Hashable {
    var id: String
    var character1Id: String
    var character2Id: String
    var relationType: String

    enum CodingKeys: String, CodingKey {
        case id
        case character1Id = "character1_id"
        case character2Id = "character2_id"
        case relationType = "relation_type"
    }

    init(id: String = IDGenerator.uid(), character1Id: String, character2Id: String, relationType: String = "") {
        self.id = id
        self.character1Id = character1Id
        self.character2Id = character2Id
        self.relationType = relationType
    }
}

/// Mirrors `canvas_nodes` (app.js:58) — relationship-map layout, keyed by
/// character rather than having its own id.
struct CanvasNode: Codable, Hashable {
    var characterId: String
    var x: Double
    var y: Double

    enum CodingKeys: String, CodingKey {
        case characterId = "character_id"
        case x, y
    }
}
