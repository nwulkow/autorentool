import Foundation
import Combine

/// Local JSON persistence for books, one file per book in
/// `Documents/Books/<sanitized-title>.json` — the exact same layout and
/// schema as the Mac app's `books/` folder (see `Book.sanitizedFilename`).
/// This is deliberately *not* a database: it's what makes Dropbox sync a
/// plain file diff instead of a translation layer.
@MainActor
final class BookStore: ObservableObject {
    @Published private(set) var books: [Book] = []

    private let fileManager = FileManager.default
    let syncIndex: SyncIndexStore

    var booksDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Books", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    init(syncIndex: SyncIndexStore? = nil) {
        self.syncIndex = syncIndex ?? SyncIndexStore()
        reload()
    }

    /// Re-reads every `*.json` file in the Books directory. Called on
    /// launch and after a sync pass brings in remote changes.
    func reload() {
        let urls = (try? fileManager.contentsOfDirectory(at: booksDirectory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        var loaded: [Book] = []
        var seen = Set<String>()
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let book = try? decoder.decode(Book.self, from: data) else {
                // Not listed, but never lost: sync treats it as changed-here
                // (content hash), and a copy goes where Settings → Backups
                // can restore it.
                try? BackupStore.snapshot(url, kind: .books, reason: "unreadable")
                continue
            }
            // A book whose title no longer sanitizes to the file it was read
            // from (hand-renamed file, or a title edited on the other app)
            // would otherwise collide with the book that legitimately owns
            // that filename and produce two rows sharing one identity.
            guard seen.insert(book.filename).inserted else { continue }
            loaded.append(book)
        }
        books = loaded.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    @discardableResult
    func save(_ book: Book, markDirty: Bool = true) -> Bool {
        let url = booksDirectory.appendingPathComponent(book.filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(book) else { return false }
        // Snapshot the version about to be replaced: always when the new one
        // lost content (an accidental chapter delete looks exactly like this)
        // or the old file doesn't decode; otherwise at most every 15 minutes.
        if FileManager.default.fileExists(atPath: url.path) {
            let previous = books.first(where: { $0.filename == book.filename }) ?? load(filename: book.filename)
            if let previous {
                if BackupStore.bookShrank(from: previous, to: book) {
                    do {
                        try BackupStore.snapshot(url, kind: .books, reason: "before content removed")
                    } catch {
                        return false // no safety copy, no destructive save
                    }
                } else {
                    try? BackupStore.snapshot(url, kind: .books, reason: "autosave", routine: true)
                }
            } else {
                do {
                    try BackupStore.snapshot(url, kind: .books, reason: "unreadable")
                } catch {
                    return false
                }
            }
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return false
        }
        if let idx = books.firstIndex(where: { $0.filename == book.filename }) {
            books[idx] = book
        } else {
            books.append(book)
            books.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        if markDirty {
            syncIndex.markDirty(filename: book.filename)
        }
        return true
    }

    func createBook(title: String, author: String) -> Book {
        let book = Book(title: title.isEmpty ? "Untitled" : title, author: author)
        save(book)
        return book
    }

    /// Saves under the new title first and only then retires the old file,
    /// so a failure in between leaves two copies rather than none. The old
    /// file is snapshotted and, on Dropbox, moved to /Trash (not deleted).
    /// The book's chat transcript and digests are copied to the new name.
    func rename(_ book: Book, to newTitle: String) -> Book {
        let oldFilename = book.filename
        var renamed = book
        renamed.title = newTitle
        guard oldFilename != renamed.filename else {
            save(renamed)
            return renamed
        }
        let newURL = booksDirectory.appendingPathComponent(renamed.filename)
        // Renaming onto another existing book would overwrite it.
        guard !fileManager.fileExists(atPath: newURL.path) else { return book }
        guard save(renamed) else { return book }
        let oldURL = booksDirectory.appendingPathComponent(oldFilename)
        if (try? BackupStore.snapshot(oldURL, kind: .books, reason: "renamed")) != nil {
            try? fileManager.removeItem(at: oldURL)
            syncIndex.markDeleted(filename: oldFilename)
        }
        books.removeAll { $0.filename == oldFilename }
        for dir in [ChatHistoryStore.directory, ChapterDigestStore.directory] {
            let from = dir.appendingPathComponent(oldFilename)
            let to = dir.appendingPathComponent(renamed.filename)
            if fileManager.fileExists(atPath: from.path), !fileManager.fileExists(atPath: to.path) {
                try? fileManager.copyItem(at: from, to: to)
            }
        }
        return renamed
    }

    /// Snapshots the book first and refuses to delete if that fails. On
    /// Dropbox the file is moved to /Trash by the next sync, never deleted.
    func delete(_ book: Book) {
        let url = booksDirectory.appendingPathComponent(book.filename)
        do {
            try BackupStore.snapshot(url, kind: .books, reason: "deleted")
        } catch {
            return
        }
        try? fileManager.removeItem(at: url)
        books.removeAll { $0.filename == book.filename }
        syncIndex.markDeleted(filename: book.filename)
    }

    func load(filename: String) -> Book? {
        let url = booksDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Book.self, from: data)
    }
}
