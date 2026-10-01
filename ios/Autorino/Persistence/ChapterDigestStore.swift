import Foundation
import CryptoKit

/// Per-book sidecar holding one `ChapterDigest` per chapter, at
/// `Documents/Digests/<sanitized-title>.json` — the same shape as
/// `ChatHistoryStore`, and deliberately *not* part of `books/*.json`: the
/// book file is the byte-compatible contract with the web app (CLAUDE.md),
/// and digests are ours alone.
///
/// Each digest is written the moment it is produced, not at the end of a
/// run. That is what makes a whole-book rebuild safely interruptible: if the
/// app is suspended, or the user cancels, everything already generated is on
/// disk and the next run simply picks up whatever is still stale.
@MainActor
final class ChapterDigestStore: ObservableObject {
    @Published private(set) var digests: [String: ChapterDigest] = [:]

    let filename: String
    private let fileManager = FileManager.default

    init(bookTitle: String) {
        self.filename = Book.sanitizedFilename(for: bookTitle)
        load()
    }

    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Digests", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var fileURL: URL { Self.directory.appendingPathComponent(filename) }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Content hashing

    /// Hashes the chapter's **plain text**, not its HTML: switching a
    /// paragraph's markup or re-saving through a different editor rewrites
    /// the HTML without changing a word, and that must not cost a
    /// regeneration.
    static func hash(_ html: String) -> String {
        let plain = PromptBuilder.htmlToPlainText(html)
        return SHA256.hash(data: Data(plain.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Queries

    func digest(for chapterId: String) -> ChapterDigest? { digests[chapterId] }

    func status(for chapter: Chapter) -> DigestStatus {
        guard let digest = digests[chapter.id] else { return .missing }
        if digest.contentHash == Self.hash(chapter.content) {
            return digest.isUserEdited ? .editedCurrent : .current
        }
        return digest.isUserEdited ? .editedStale : .stale
    }

    /// Chapters with no digest, or whose prose has moved on since one was
    /// made. A hand-edited digest whose chapter changed is *not* included:
    /// regenerating it would silently throw away the user's writing, so it
    /// has to be asked for one chapter at a time.
    func needingGeneration(in book: Book) -> [(index: Int, chapter: Chapter)] {
        book.chapters.enumerated().compactMap { index, chapter in
            switch status(for: chapter) {
            case .missing, .stale: return (index, chapter)
            case .current, .editedCurrent, .editedStale: return nil
            }
        }
    }

    /// Every stored digest in manuscript order, with staleness resolved, for
    /// the chat prompt. Chapters without one are simply absent — a half-built
    /// set is still worth sending, and saying "no summary" for twenty
    /// chapters would only invite the model to guess at them.
    func promptEntries(in book: Book) -> [PromptBuilder.DigestContextEntry] {
        book.chapters.enumerated().compactMap { index, chapter in
            guard let digest = digests[chapter.id] else { return nil }
            let label = chapter.name.isEmpty ? chapter.label : chapter.name
            return PromptBuilder.DigestContextEntry(
                index: index,
                title: label.isEmpty ? "\(index + 1)" : label,
                digest: digest,
                isStale: digest.contentHash != Self.hash(chapter.content)
            )
        }
    }

    // MARK: - Mutation

    func upsert(_ digest: ChapterDigest) {
        // Regenerating over a hand-edited digest replaces the user's writing.
        if digests[digest.chapterId]?.isUserEdited == true {
            try? BackupStore.snapshot(fileURL, kind: .digests, reason: "before regenerate")
        }
        digests[digest.chapterId] = digest
        persist()
    }

    /// Records a hand edit. Stamping `editedAt` is what flips this record
    /// from cache to user data — after this, `needingGeneration` leaves it
    /// alone and only an explicit per-chapter regenerate touches it.
    func saveEdited(_ digest: ChapterDigest) {
        var edited = digest
        edited.editedAt = Date()
        digests[digest.chapterId] = edited
        persist()
    }

    func remove(chapterId: String) {
        try? BackupStore.snapshot(fileURL, kind: .digests, reason: "before remove")
        digests.removeValue(forKey: chapterId)
        persist()
    }

    /// Drops digests whose chapter no longer exists, so a deleted chapter
    /// doesn't leave a record that later prompts would still read.
    func pruneOrphans(in book: Book) {
        let live = Set(book.chapters.map(\.id))
        let orphans = digests.keys.filter { !live.contains($0) }
        guard !orphans.isEmpty else { return }
        try? BackupStore.snapshot(fileURL, kind: .digests, reason: "before prune")
        orphans.forEach { digests.removeValue(forKey: $0) }
        persist()
    }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? Self.decoder.decode([String: ChapterDigest].self, from: data) else { return }
        digests = decoded
    }

    func reload() { load() }

    private func persist() {
        guard let data = try? Self.encoder.encode(digests) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Where a chapter stands relative to its digest — drives the row badge and
/// what the per-chapter button offers to do.
enum DigestStatus: Hashable {
    case missing
    case current
    case stale
    case editedCurrent
    case editedStale

    var isStale: Bool { self == .stale || self == .editedStale }
    var isUserEdited: Bool { self == .editedCurrent || self == .editedStale }
}
