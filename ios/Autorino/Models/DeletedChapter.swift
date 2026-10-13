import Foundation

/// A chapter in the book's "Deleted chapters" bin (`deleted_chapters`).
/// Deleting a chapter moves it here; only deleting it from the bin removes
/// it from the book, and even then the save snapshots the book first
/// (`BackupStore.bookShrank` counts the bin), so it stays recoverable from
/// Backups.
///
/// On disk an entry is the chapter itself, flat, plus where it stood:
/// `deleted_at`, `deleted_position` (its index then) and `deleted_after_id`
/// (the chapter before it, `null` when it was first). Same shape as
/// `serializeDeletedChapter` in app.js.
struct DeletedChapter: Codable, Identifiable, Hashable {
    var chapter: Chapter
    var deletedAt: String
    var position: Int
    var afterChapterId: String?

    var id: String { chapter.id }

    private enum Keys: String, CodingKey {
        case deletedAt = "deleted_at"
        case position = "deleted_position"
        case afterChapterId = "deleted_after_id"
    }

    init(chapter: Chapter, deletedAt: String = ISO8601DateFormatter().string(from: Date()), position: Int, afterChapterId: String?) {
        self.chapter = chapter
        self.deletedAt = deletedAt
        self.position = position
        self.afterChapterId = afterChapterId
    }

    init(from decoder: Decoder) throws {
        chapter = try Chapter(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt) ?? ""
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
        afterChapterId = try c.decodeIfPresent(String.self, forKey: .afterChapterId)
    }

    func encode(to encoder: Encoder) throws {
        try chapter.encode(to: encoder)
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(deletedAt, forKey: .deletedAt)
        try c.encode(position, forKey: .position)
        try c.encode(afterChapterId, forKey: .afterChapterId)
    }
}

/// Bin operations. Same rules as the "Deleted chapters" methods in app.js.
extension Book {
    /// Where a chapter goes back: right after the chapter it followed, at
    /// the top if it was first, else at its old index (clamped).
    static func restoreIndex(afterChapterId: String?, position: Int, in chapters: [Chapter]) -> Int {
        guard let after = afterChapterId, !after.isEmpty else { return 0 }
        if let i = chapters.firstIndex(where: { $0.id == after }) { return i + 1 }
        return min(max(position, 0), chapters.count)
    }

    mutating func moveChaptersToBin(at offsets: IndexSet) {
        // Highest index first so the remaining offsets stay valid.
        for index in offsets.sorted(by: >) {
            let chapter = chapters[index]
            deletedChapters.append(DeletedChapter(
                chapter: chapter,
                position: index,
                afterChapterId: index > 0 ? chapters[index - 1].id : nil
            ))
            chapters.remove(at: index)
        }
    }

    /// Puts a chapter back where it was. A chapter with the same id already
    /// in the book (possible after a sync merge) gets a fresh id, so both
    /// stay.
    mutating func insertRestored(_ chapter: Chapter, afterChapterId: String?, position: Int) {
        var restored = chapter
        if chapters.contains(where: { $0.id == restored.id }) {
            restored.id = IDGenerator.uid()
        }
        let at = Book.restoreIndex(afterChapterId: afterChapterId, position: position, in: chapters)
        chapters.insert(restored, at: at)
    }

    mutating func restoreFromBin(_ id: String) {
        guard let i = deletedChapters.firstIndex(where: { $0.id == id }) else { return }
        let entry = deletedChapters.remove(at: i)
        insertRestored(entry.chapter, afterChapterId: entry.afterChapterId, position: entry.position)
    }

    mutating func deletePermanently(_ id: String) {
        deletedChapters.removeAll { $0.id == id }
    }
}
