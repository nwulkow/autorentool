import SwiftUI

/// "Deleted books": books moved to the bin (`BookStore.deletedBooks`) plus
/// books that only survive in Backups. Restoring brings a book back under its
/// own title; deleting from the bin is the only permanent delete (snapshot,
/// then Dropbox Trash), after which the book shows up under "Found in
/// backups". Mirrors the deleted-books modal in app.js.
struct DeletedBooksView: View {
    /// Observed directly: `AppEnvironment` doesn't republish store changes.
    @EnvironmentObject private var bookStore: BookStore
    /// `nil` while the backups are being read.
    @State private var recoverable: [BackupStore.RecoverableBook]?
    @State private var confirmingDelete: Book?
    @State private var message: String?

    var body: some View {
        List {
            Section {
                if bookStore.deletedBooks.isEmpty {
                    Text("No deleted books.").foregroundStyle(.secondary)
                }
                ForEach(bookStore.deletedBooks) { book in
                    row(book, detail: deletedText(book.deletedAt)) {
                        bookStore.restoreFromBin(book)
                    }
                    .swipeActions {
                        Button(role: .destructive) { confirmingDelete = book } label: {
                            Label("Delete permanently", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("Deleted books")
            } footer: {
                Text("Restore puts a book back into your library. Swipe left to delete one permanently; it then also goes to the Dropbox Trash, and a copy stays in Backups.")
            }

            Section {
                if let recoverable {
                    if recoverable.isEmpty {
                        Text("No other books found.").foregroundStyle(.secondary)
                    }
                    ForEach(recoverable) { item in
                        row(item.book, detail: String(localized: "Backup from \(item.snapshotDate.formatted(date: .abbreviated, time: .shortened))")) {
                            if bookStore.restoreFromBackup(item.book) {
                                self.recoverable?.removeAll { $0.id == item.id }
                            } else {
                                message = String(localized: "A book with this title already exists.")
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            } header: {
                Text("Found in backups")
            } footer: {
                Text("Books that are gone from your library but still in the backups on this device.")
            }
        }
        .navigationTitle("Deleted books")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete this book permanently?",
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible,
            presenting: confirmingDelete
        ) { book in
            Button("Delete permanently", role: .destructive) {
                bookStore.delete(book)
                Task { await loadRecoverable() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It is removed from this device and moved to the Dropbox Trash. A copy stays in Backups and can be restored from “Found in backups”.")
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .task { await loadRecoverable() }
    }

    private func row(_ book: Book, detail: String, restore: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(Theme.rowTitle)
                    .foregroundStyle(Theme.ink)
                Text("\(book.chapters.count) chapters · \(detail)")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            Button("Restore", action: restore)
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
        }
    }

    private func loadRecoverable() async {
        let dir = bookStore.booksDirectory
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        recoverable = await Task.detached { BackupStore.recoverableBooks(existing: existing) }.value
    }

    private func deletedText(_ stamp: String?) -> String {
        let f = ISO8601DateFormatter()
        guard let stamp, let date = f.date(from: stamp) else { return String(localized: "Deleted") }
        return String(localized: "Deleted \(date.formatted(date: .abbreviated, time: .shortened))")
    }
}

/// `DeletedBooksView` as a sheet, from the library.
struct DeletedBooksSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DeletedBooksView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}
