import SwiftUI

struct BookListView: View {
    @EnvironmentObject private var env: AppEnvironment
    /// Observed directly — through `env` the list never saw the store change
    /// (a book deleted or restored stayed on screen until the next relaunch).
    @EnvironmentObject private var bookStore: BookStore
    @State private var showingNewBook = false
    @State private var resolving: Book?
    @State private var showingBin = false
    // Explicit path, owned by `RootView`'s `NavigationStack` and passed in
    // (rather than letting the stack manage it internally) so a rename can
    // rewrite the pushed title in place — see `navigationDestination`
    // below. Without this, renaming the open book leaves the path holding
    // the pre-rename title, which no longer matches any entry in
    // `bookStore.books` (`rename` removes the old-titled entry once it
    // saves under the new one); the destination then has nothing to
    // resolve, and taps on the book list can stop navigating until the app
    // restarts.
    @Binding var path: NavigationPath

    var body: some View {
        Group {
            if bookStore.books.isEmpty && bookStore.deletedBooks.isEmpty {
                EmptyStateView(
                    systemImage: "books.vertical",
                    title: String(localized: "Your Books"),
                    message: String(localized: "Create your first book to get started."),
                    actionTitle: String(localized: "Create your first book")
                ) { showingNewBook = true }
            } else {
                List {
                    Text("Your Books")
                        .font(Theme.title)
                        .foregroundStyle(Theme.ink)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))

                    ForEach(bookStore.books) { book in
                        // Conflict copies left by sync are not books of their
                        // own here; they hang off their main book's row.
                        VStack(alignment: .leading, spacing: 8) {
                            NavigationLink(value: book.filename) {
                                BookRowView(book: book)
                            }
                            BookConflictBadge(store: bookStore, book: book) { resolving = book }
                        }
                        .bookCardRow()
                        // Into "Deleted books", not gone: see `DeletedBooksView`.
                        // Not `.onDelete` / a `.destructive` button: both remove
                        // the row on screen before the store publishes, and with
                        // the bin row appearing in the same update the list
                        // desynced and crashed on its next layout. A plain
                        // button lets the store change drive the update.
                        .swipeActions {
                            Button { bookStore.moveToBin(book) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }

                    if !bookStore.deletedBooks.isEmpty {
                        Button { showingBin = true } label: {
                            Label("Deleted books (\(bookStore.deletedBooks.count))", systemImage: "trash")
                                .font(.subheadline)
                                .foregroundStyle(Theme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 6)
                        .bookCardRow()
                    }
                }
                .listStyle(.plain)
                .paperBackground()
                .refreshable { await env.syncNow() }
            }
        }
        // The heading lives in the content (a big serif "Your Books"),
        // mirroring `.saved-section h2` in the web app where it's also a
        // content heading rather than chrome — so the bar itself carries
        // only the + / gear buttons.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: String.self) { filename in
            // Routed by filename, not title: two titles can sanitize to one
            // filename, and a title lookup would then resolve ambiguously
            // (see `Book.id`).
            if let book = bookStore.books.first(where: { $0.filename == filename }) {
                BookTabContainer(editor: BookEditor(book: book, bookStore: bookStore)) { newTitle in
                    // Keep the pushed path element in sync with a rename so
                    // it keeps resolving against `bookStore.books` (see
                    // the note on `path` above) instead of pointing at a
                    // filename that no longer exists.
                    if !path.isEmpty { path.removeLast() }
                    path.append(Book.sanitizedFilename(for: newTitle))
                }
            } else {
                // The pushed filename no longer matches any book (renamed
                // from elsewhere, deleted, or a stale path entry from before
                // a sync reload) — pop back to the list instead of leaving a
                // dead screen the user can't navigate away from.
                Color.clear.onAppear { if !path.isEmpty { path.removeLast() } }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !bookStore.books.isEmpty {
                    Button {
                        showingNewBook = true
                    } label: {
                        Label("New Book", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showingNewBook) {
            NewBookSheet()
        }
        .sheet(isPresented: $showingBin) {
            DeletedBooksSheet()
        }
        .sheet(item: $resolving) { book in
            ConflictResolverView(store: bookStore, book: book)
        }
    }
}

/// The `.book-card` treatment (styles.css:94-101): serif title, author in
/// muted brown, and a row of counts along the bottom.
struct BookRowView: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(book.title)
                .font(Theme.serif(19, relativeTo: .headline).weight(.bold))
                .foregroundStyle(Theme.ink)

            if !book.author.isEmpty {
                Text("by \(book.author)")
                    .font(Theme.serif(14, relativeTo: .subheadline).italic())
                    .foregroundStyle(Theme.muted)
            }

            Divider()
                .overlay(Theme.line)
                .padding(.vertical, 2)

            HStack(spacing: 14) {
                Label("\(book.characters.count)", systemImage: "person.2")
                Label("\(book.chapters.count)", systemImage: "doc.text")
                Label("\(book.questions.count)", systemImage: "questionmark.circle")
                Label("\(book.locations.count)", systemImage: "mappin.and.ellipse")
            }
            .font(.caption)
            .foregroundStyle(Theme.muted)
        }
        .bookCard()
    }
}
