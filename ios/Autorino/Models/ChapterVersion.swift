import Foundation

/// An alternative version of a chapter (docs/chapter-versions-plan.md).
/// Mirrors `serializeChapter`'s `versions` entries in app.js. The chapter's
/// own `content`/`comments` are version 1, the main version — the only one
/// counted in word totals, full text, exports and digests.
struct ChapterVersion: Codable, Identifiable, Hashable {
    var id: String
    /// Slot number, ≥ 2. Stays put on a swap: the text moves, not the number.
    var number: Int
    var name: String
    var content: String
    var comments: [Comment]
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, number, name, content, comments
        case createdAt = "created_at"
    }

    init(id: String = IDGenerator.uid(), number: Int, name: String = "", content: String = "", comments: [Comment] = [], createdAt: String = ISO8601DateFormatter().string(from: Date())) {
        self.id = id
        self.number = number
        self.name = name
        self.content = content
        self.comments = comments
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? IDGenerator.uid()
        number = try c.decodeIfPresent(Int.self, forKey: .number) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        comments = try c.decodeIfPresent([Comment].self, forKey: .comments) ?? []
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

/// Version operations, identical to the `chapterVersion*` helpers in app.js.
/// A `slot` of `nil` means the main version (the chapter itself).
extension Chapter {
    /// Where a new version's text comes from.
    enum VersionSource: Hashable {
        case empty
        case main
        case version(String)
    }

    var nextVersionNumber: Int {
        (versions.map(\.number).max() ?? 1) + 1
    }

    func version(_ id: String) -> ChapterVersion? {
        versions.first { $0.id == id }
    }

    func content(slot: String?) -> String {
        guard let slot else { return content }
        return version(slot)?.content ?? ""
    }

    mutating func setContent(_ html: String, slot: String?) {
        guard let slot else { content = html; return }
        guard let i = versions.firstIndex(where: { $0.id == slot }) else { return }
        versions[i].content = html
    }

    func comments(slot: String?) -> [Comment] {
        guard let slot else { return comments }
        return version(slot)?.comments ?? []
    }

    mutating func setComments(_ newValue: [Comment], slot: String?) {
        guard let slot else { comments = newValue; return }
        guard let i = versions.firstIndex(where: { $0.id == slot }) else { return }
        versions[i].comments = newValue
    }

    func versionNumber(slot: String?) -> Int {
        guard let slot else { return 1 }
        return version(slot)?.number ?? 1
    }

    func versionName(slot: String?) -> String {
        guard let slot else { return versionName }
        return version(slot)?.name ?? ""
    }

    /// Comments are not copied: their ranges belong to the source text.
    @discardableResult
    mutating func createVersion(from source: VersionSource, name: String) -> String {
        let text: String
        switch source {
        case .empty: text = ""
        case .main: text = content
        case .version(let id): text = version(id)?.content ?? ""
        }
        let new = ChapterVersion(number: nextVersionNumber, name: name, content: text)
        versions.append(new)
        return new.id
    }

    /// Exchanges text, comments and name between main and `id`; numbers,
    /// ids and creation dates stay in their slots.
    mutating func swapWithMain(_ id: String) {
        guard let i = versions.firstIndex(where: { $0.id == id }) else { return }
        swap(&content, &versions[i].content)
        swap(&comments, &versions[i].comments)
        swap(&versionName, &versions[i].name)
    }

    mutating func renameVersion(slot: String?, to name: String) {
        guard let slot else { versionName = name; return }
        guard let i = versions.firstIndex(where: { $0.id == slot }) else { return }
        versions[i].name = name
    }

    mutating func deleteVersion(_ id: String) {
        versions.removeAll { $0.id == id }
    }

    /// "V2" or "V2 · darker ending".
    func versionLabel(slot: String?) -> String {
        let name = versionName(slot: slot)
        let number = "V\(versionNumber(slot: slot))"
        return name.isEmpty ? number : "\(number) · \(name)"
    }
}
