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
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let book = try? decoder.decode(Book.self, from: data) else { continue }
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
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return false
        }
        if let idx = books.firstIndex(where: { $0.title == book.title }) {
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

    func rename(_ book: Book, to newTitle: String) -> Book {
        let oldFilename = book.filename
        var renamed = book
        renamed.title = newTitle
        let oldURL = booksDirectory.appendingPathComponent(oldFilename)
        if oldFilename != renamed.filename {
            try? fileManager.removeItem(at: oldURL)
            syncIndex.markDeleted(filename: oldFilename)
            books.removeAll { $0.title == book.title }
        }
        save(renamed)
        return renamed
    }

    func delete(_ book: Book) {
        let url = booksDirectory.appendingPathComponent(book.filename)
        try? fileManager.removeItem(at: url)
        books.removeAll { $0.title == book.title }
        syncIndex.markDeleted(filename: book.filename)
    }

    func load(filename: String) -> Book? {
        let url = booksDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Book.self, from: data)
    }
}
