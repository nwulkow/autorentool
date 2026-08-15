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
                    if !env.syncStatus.conflicts.isEmpty {
                        Section {
                            NavigationLink {
                                SettingsView()
                            } label: {
                                Label("\(env.syncStatus.conflicts.count) sync conflict(s) — review in Settings", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    ForEach(env.bookStore.books) { book in
                        NavigationLink(value: book.title) {
                            BookRowView(book: book)
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet { env.bookStore.delete(env.bookStore.books[index]) }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await env.syncNow() }
            }
        }
        .navigationTitle("Your Books")
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

struct BookRowView: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(book.title).font(.headline)
            if !book.author.isEmpty {
                Text("by \(book.author)").font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Label("\(book.characters.count)", systemImage: "person.2")
                Label("\(book.chapters.count)", systemImage: "doc.text")
                Label("\(book.questions.count)", systemImage: "questionmark.circle")
                Label("\(book.locations.count)", systemImage: "mappin.and.ellipse")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
