import SwiftUI

struct BookListView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var showingNewBook = false
    @State private var showingConflictSettings = false
    // Explicit path, owned by `RootView`'s `NavigationStack` and passed in
    // (rather than letting the stack manage it internally) so a rename can
    // rewrite the pushed title in place — see `navigationDestination`
    // below. Without this, renaming the open book leaves the path holding
    // the pre-rename title, which no longer matches any entry in
    // `env.bookStore.books` (`rename` removes the old-titled entry once it
    // saves under the new one); the destination then has nothing to
    // resolve, and taps on the book list can stop navigating until the app
    // restarts.
    @Binding var path: NavigationPath

    var body: some View {
        Group {
            if env.bookStore.books.isEmpty {
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

                    if !env.syncStatus.conflicts.isEmpty {
                        // A sheet, not a NavigationLink push: `SettingsView`
                        // owns its own `NavigationStack` and a
                        // `dismiss()`-driven Done button, which only behaves
                        // correctly when presented modally — see the note on
                        // `MoreTabView`.
                        Button {
                            showingConflictSettings = true
                        } label: {
                            Label("\(env.syncStatus.conflicts.count) sync conflict(s) — review in Settings", systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Theme.danger)
                                .bookCard(padding: 12)
                        }
                        .buttonStyle(.plain)
                        .bookCardRow()
                    }

                    ForEach(env.bookStore.books) { book in
                        NavigationLink(value: book.title) {
                            BookRowView(book: book)
                        }
                        .bookCardRow()
                    }
                    .onDelete { indexSet in
                        for index in indexSet { env.bookStore.delete(env.bookStore.books[index]) }
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
        .navigationDestination(for: String.self) { title in
            if let book = env.bookStore.books.first(where: { $0.title == title }) {
                BookTabContainer(editor: BookEditor(book: book, bookStore: env.bookStore)) { newTitle in
                    // Keep the pushed path element in sync with a rename so
                    // it keeps resolving against `env.bookStore.books` (see
                    // the note on `path` above) instead of pointing at a
                    // title that no longer exists.
                    if !path.isEmpty { path.removeLast() }
                    path.append(newTitle)
                }
            } else {
                // The pushed title no longer matches any book (renamed from
                // elsewhere, deleted, or a stale path entry from before a
                // sync reload) — pop back to the list instead of leaving a
                // dead screen the user can't navigate away from.
                Color.clear.onAppear { if !path.isEmpty { path.removeLast() } }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !env.bookStore.books.isEmpty {
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
        .sheet(isPresented: $showingConflictSettings) {
            SettingsView()
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
