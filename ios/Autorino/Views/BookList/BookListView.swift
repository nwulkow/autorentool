import SwiftUI

struct BookListView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var showingNewBook = false

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
                        NavigationLink {
                            SettingsView()
                        } label: {
                            Label("\(env.syncStatus.conflicts.count) sync conflict(s) — review in Settings", systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Theme.danger)
                                .bookCard(padding: 12)
                        }
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
                BookTabContainer(editor: BookEditor(book: book, bookStore: env.bookStore))
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
