import Foundation

/// Mirrors `serializeBook`'s `chapters` shape (app.js:49-52). `content`
/// stays HTML on disk (same as today's Quill output) so files remain
/// readable by the Mac app — no new storage format is introduced.
///
/// `content`/`comments` are always the **main version** (V1); alternatives
/// live in `versions` (see `ChapterVersion`). Both version keys are left out
/// of the JSON when empty, matching `serializeChapter` in app.js, so a book
/// without versions stays byte-identical across the two apps.
struct Chapter: Codable, Identifiable, Hashable {
    var id: String
    var label: String
    var name: String
    var content: String
    var comments: [Comment]
    /// Optional name of the main version — swaps with `ChapterVersion.name`.
    var versionName: String
    var versions: [ChapterVersion]

    enum CodingKeys: String, CodingKey {
        case id, label, name, content, comments, versions
        case versionName = "version_name"
    }

    init(id: String = IDGenerator.uid(), label: String = "", name: String = "", content: String = "", comments: [Comment] = [], versionName: String = "", versions: [ChapterVersion] = []) {
        self.id = id
        self.label = label
        self.name = name
        self.content = content
        self.comments = comments
        self.versionName = versionName
        self.versions = versions
    }

    /// Lenient for the reason `Comment` is: a chapter that fails to decode
    /// hides its whole book from the library.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? IDGenerator.uid()
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        comments = try c.decodeIfPresent([Comment].self, forKey: .comments) ?? []
        versionName = try c.decodeIfPresent(String.self, forKey: .versionName) ?? ""
        versions = try c.decodeIfPresent([ChapterVersion].self, forKey: .versions) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(name, forKey: .name)
        try c.encode(content, forKey: .content)
        try c.encode(comments, forKey: .comments)
        if !versionName.isEmpty { try c.encode(versionName, forKey: .versionName) }
        if !versions.isEmpty { try c.encode(versions, forKey: .versions) }
    }
}

/// Mirrors chapter `comments` (app.js:51). Anchored by a plain-text
/// range (`rangeIndex`/`rangeLength`) into the chapter's text, same
/// concept as Quill's range — just no framework dependency on iOS.
///
/// The range is **optional**, because app.js only captures one when there
/// was a live selection at the time: `addComment` (app.js:1665-1676) leaves
/// `rangeIndex`/`rangeLength` `null` for an unanchored comment, and older
/// books omit the keys entirely. Requiring them made a single such comment
/// fail the whole `Book` decode, and since `BookStore.reload()` skips books
/// that throw, the book silently vanished from the library rather than
/// showing an error. app.js already guards on `rangeIndex == null`
/// (app.js:1680) — this mirrors that, and re-encodes `nil` back to `null`
/// so the Mac app keeps reading the file unchanged.
struct Comment: Codable, Identifiable, Hashable {
    var id: String
    var text: String
    var selection: String
    var rangeIndex: Int?
    var rangeLength: Int?
    var date: String

    init(id: String = IDGenerator.uid(), text: String = "", selection: String = "", rangeIndex: Int? = nil, rangeLength: Int? = nil, date: String = ISO8601DateFormatter().string(from: Date())) {
        self.id = id
        self.text = text
        self.selection = selection
        self.rangeIndex = rangeIndex
        self.rangeLength = rangeLength
        self.date = date
    }

    /// Tolerates missing `id`/`text`/`selection`/`date` too — the same
    /// leniency `TimelineConfig` needs, for the same reason: these files are
    /// written by another app whose shape drifts by feature, not by version.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? IDGenerator.uid()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        selection = try c.decodeIfPresent(String.self, forKey: .selection) ?? ""
        rangeIndex = try c.decodeIfPresent(Int.self, forKey: .rangeIndex)
        rangeLength = try c.decodeIfPresent(Int.self, forKey: .rangeLength)
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
    }
}

/// Mirrors `passages` (app.js:53) — a chapter-scoped text anchor used to
/// narrow LLM context to a specific excerpt.
struct Passage: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var chapterId: String
    var startText: String
    var endText: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case chapterId = "chapter_id"
        case startText = "start_text"
        case endText = "end_text"
    }

    init(id: String = IDGenerator.uid(), name: String = "Passage", chapterId: String = "", startText: String = "", endText: String = "") {
        self.id = id
        self.name = name
        self.chapterId = chapterId
        self.startText = startText
        self.endText = endText
    }
}
