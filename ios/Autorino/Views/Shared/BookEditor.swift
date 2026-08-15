import Foundation
import Combine

/// Wraps one open `Book` for editing. Publishing `book` and debouncing the
/// save is the native replacement for app.js's 10s `setInterval` autosave
/// (app.js `mounted()`/`_autosaveTimer`) — edits save themselves shortly
/// after the user pauses, no polling timer needed.
@MainActor
final class BookEditor: ObservableObject {
    @Published var book: Book
    private let bookStore: BookStore
    private var cancellable: AnyCancellable?

    init(book: Book, bookStore: BookStore) {
        self.book = book
        self.bookStore = bookStore
        cancellable = $book
            .dropFirst()
            .debounce(for: .seconds(1.5), scheduler: DispatchQueue.main)
            .sink { [weak self] updated in
                self?.bookStore.save(updated)
            }
    }

    func saveNow() {
        bookStore.save(book)
    }
}
