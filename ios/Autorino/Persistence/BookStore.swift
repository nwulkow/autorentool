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
    /// Conflict copies left by sync, listed under their main book rather
    /// than in `books` — see `BookConflicts.swift`.
    @Published private(set) var conflictCopies: [ConflictCopy] = []
    /// Books in "Deleted books" (`Book.deletedAt` set), newest first. Their
    /// files stay in place and sync as usual; they are just not in `books`.
    @Published private(set) var deletedBooks: [Book] = []

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
        let urls = ((try? fileManager.contentsOfDirectory(at: booksDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        let names = Set(urls.map(\.lastPathComponent))
        let decoder = JSONDecoder()
        var decoded: [(url: URL, book: Book)] = []
        var candidates: [(url: URL, info: (base: String, label: String, stamp: String))] = []
        for url in urls {
            if let info = BookConflicts.classify(url.lastPathComponent, existing: names) {
                candidates.append((url, info))
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let book = try? decoder.decode(Book.self, from: data) else {
                // Not listed, but never lost: sync treats it as changed-here
                // (content hash), and a copy goes where Settings → Backups
                // can restore it.
                try? BackupStore.snapshot(url, kind: .books, reason: "unreadable")
                continue
            }
            decoded.append((url, book))
        }
        // A conflict copy only hides behind a main book that is readable;
        // otherwise it may be the only usable copy and is listed as a book.
        let readableMains = Set(decoded.map(\.url.lastPathComponent))
        var copies: [ConflictCopy] = []
        for (url, info) in candidates {
            if readableMains.contains(info.base) {
                copies.append(ConflictCopy(filename: url.lastPathComponent, baseFilename: info.base,
                                           label: info.label, stamp: info.stamp,
                                           object: BookConflicts.readObject(url)))
            } else if let data = try? Data(contentsOf: url), let book = try? decoder.decode(Book.self, from: data) {
                decoded.append((url, book))
            }
        }
        // A book whose title no longer sanitizes to the file it was read
        // from (hand-renamed file, or a title edited on the other app) would
        // otherwise collide with the book that legitimately owns that
        // filename and produce two rows sharing one identity. The rightful
        // owner goes first so it is the one listed — and the one saves go to.
        decoded.sort { ($0.book.filename == $0.url.lastPathComponent) && ($1.book.filename != $1.url.lastPathComponent) }
        var loaded: [Book] = []
        var seen = Set<String>()
        for (_, book) in decoded where seen.insert(book.filename).inserted {
            loaded.append(book)
        }
        books = Self.sortedByTitle(loaded.filter { $0.deletedAt == nil })
        deletedBooks = Self.sortedByDeletion(loaded.filter { $0.deletedAt != nil })
        conflictCopies = copies.sorted { $0.stamp < $1.stamp }
    }

    private static func sortedByTitle(_ list: [Book]) -> [Book] {
        list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private static func sortedByDeletion(_ list: [Book]) -> [Book] {
        list.sorted { ($0.deletedAt ?? "") > ($1.deletedAt ?? "") }
    }

    /// Only `restoring` takes a book out of "Deleted books". Any other save
    /// onto a binned book's file (an editor still open while the other app
    /// deleted it) keeps the edits but leaves the book in the bin.
    @discardableResult
    func save(_ book: Book, markDirty: Bool = true, restoring: Bool = false) -> Bool {
        var book = book
        let url = booksDirectory.appendingPathComponent(book.filename)
        if !restoring, book.deletedAt == nil,
           let binnedAt = deletedBooks.first(where: { $0.filename == book.filename })?.deletedAt {
            book.deletedAt = binnedAt
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(book) else { return false }
        // Snapshot the version about to be replaced: always when the new one
        // lost content (an accidental chapter delete looks exactly like this)
        // or the old file doesn't decode; otherwise at most every 15 minutes.
        if FileManager.default.fileExists(atPath: url.path) {
            let previous = (books + deletedBooks).first(where: { $0.filename == book.filename }) ?? load(filename: book.filename)
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
        if book.deletedAt == nil {
            deletedBooks.removeAll { $0.filename == book.filename }
            if let idx = books.firstIndex(where: { $0.filename == book.filename }) {
                books[idx] = book
            } else {
                books = Self.sortedByTitle(books + [book])
            }
        } else {
            books.removeAll { $0.filename == book.filename }
            deletedBooks = Self.sortedByDeletion(deletedBooks.filter { $0.filename != book.filename } + [book])
        }
        if markDirty {
            syncIndex.markDirty(filename: book.filename)
        }
        return true
    }

    /// A title whose file already exists (a live book, or one in "Deleted
    /// books") gets a number, so a new book never replaces an old one.
    func createBook(title: String, author: String) -> Book {
        let base = title.isEmpty ? "Untitled" : title
        var candidate = base
        var n = 2
        while fileManager.fileExists(atPath: booksDirectory.appendingPathComponent(Book.sanitizedFilename(for: candidate)).path) {
            candidate = "\(base) \(n)"
            n += 1
        }
        let book = Book(title: candidate, author: author)
        save(book)
        return book
    }

    /// "Deleting" a book: it moves to "Deleted books". The file stays, so
    /// this is an ordinary (synced) save, not a removal.
    func moveToBin(_ book: Book) {
        var binned = load(filename: book.filename) ?? book
        binned.deletedAt = ISO8601DateFormatter().string(from: Date())
        save(binned)
    }

    @discardableResult
    func restoreFromBin(_ book: Book) -> Bool {
        var restored = load(filename: book.filename) ?? book
        restored.deletedAt = nil
        return save(restored, restoring: true)
    }

    /// Brings back a book that only survives in Backups, under its own title.
    /// Never overwrites: refuses when that filename is taken.
    @discardableResult
    func restoreFromBackup(_ book: Book) -> Bool {
        var restored = book
        restored.deletedAt = nil
        guard !fileManager.fileExists(atPath: booksDirectory.appendingPathComponent(restored.filename).path) else { return false }
        return save(restored)
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

    /// Permanent delete — only offered in "Deleted books".
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
        deletedBooks.removeAll { $0.filename == book.filename }
        syncIndex.markDeleted(filename: book.filename)
    }

    func load(filename: String) -> Book? {
        let url = booksDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Book.self, from: data)
    }
}
