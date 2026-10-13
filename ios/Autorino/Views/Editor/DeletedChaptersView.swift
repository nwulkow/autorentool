import SwiftUI

/// The book's "Deleted chapters" bin (`Book.deletedChapters`) plus chapters
/// that only survive in this book's backups. Restoring puts a chapter back
/// where it was; deleting from the bin is the only permanent delete, and its
/// save snapshots the book first, so the chapter then shows up under
/// "Found in backups". Mirrors the deleted-chapters modal in app.js.
struct DeletedChaptersView: View {
    @ObservedObject var editor: BookEditor
    @Environment(\.dismiss) private var dismiss
    /// `nil` while the backups are being read.
    @State private var recoverable: [BackupStore.RecoverableChapter]?
    @State private var confirmingDelete: DeletedChapter?

    private var bin: [DeletedChapter] {
        editor.book.deletedChapters.sorted { $0.deletedAt > $1.deletedAt }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if bin.isEmpty {
                        Text("No deleted chapters.").foregroundStyle(.secondary)
                    }
                    ForEach(bin) { entry in
                        row(entry.chapter, detail: deletedText(entry.deletedAt)) {
                            editor.book.restoreFromBin(entry.id)
                        }
                        .swipeActions {
                            Button(role: .destructive) { confirmingDelete = entry } label: {
                                Label("Delete permanently", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Deleted chapters")
                } footer: {
                    Text("Restore puts a chapter back where it was. Swipe left to delete one permanently; a copy stays in Backups.")
                }

                Section {
                    if let recoverable {
                        if recoverable.isEmpty {
                            Text("No other chapters found.").foregroundStyle(.secondary)
                        }
                        ForEach(recoverable) { item in
                            row(item.chapter, detail: String(localized: "Backup from \(item.snapshotDate.formatted(date: .abbreviated, time: .shortened))")) {
                                editor.book.insertRestored(item.chapter, afterChapterId: item.afterChapterId, position: item.position)
                                self.recoverable?.removeAll { $0.id == item.id }
                            }
                        }
                    } else {
                        ProgressView()
                    }
                } header: {
                    Text("Found in backups")
                } footer: {
                    Text("Chapters that are no longer in this book but are still in its backups on this device.")
                }
            }
            .navigationTitle("Deleted chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog(
                "Delete this chapter permanently?",
                isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
                titleVisibility: .visible,
                presenting: confirmingDelete
            ) { entry in
                Button("Delete permanently", role: .destructive) {
                    editor.book.deletePermanently(entry.id)
                    Task { await loadRecoverable() }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("It is removed from the book. A copy stays in Backups and can be restored from “Found in backups”.")
            }
            .task { await loadRecoverable() }
        }
    }

    private func row(_ chapter: Chapter, detail: String, restore: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            NavigationLink {
                DeletedChapterPreview(chapter: chapter)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chapterTitle(chapter))
                        .font(Theme.rowTitle)
                        .foregroundStyle(Theme.ink)
                    Text("\(chapter.wordCount) words · \(detail)")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
            }
            Button("Restore", action: restore)
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
        }
    }

    private func loadRecoverable() async {
        let book = editor.book
        recoverable = await Task.detached { BackupStore.recoverableChapters(for: book) }.value
    }

    private func deletedText(_ stamp: String) -> String {
        guard let date = Self.parse(stamp) else { return String(localized: "Deleted") }
        return String(localized: "Deleted \(date.formatted(date: .abbreviated, time: .shortened))")
    }

    /// app.js writes `toISOString()` (with milliseconds), this app without.
    private static func parse(_ stamp: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: stamp) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: stamp)
    }
}

private func chapterTitle(_ chapter: Chapter) -> String {
    let parts = [chapter.label, chapter.name].filter { !$0.isEmpty }
    return parts.isEmpty ? String(localized: "Untitled chapter") : parts.joined(separator: " · ")
}

/// Read-only text of a deleted chapter, to check it is the right one before
/// restoring.
private struct DeletedChapterPreview: View {
    let chapter: Chapter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(BookConflicts.paragraphs(chapter.content).enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(Theme.serif(17, relativeTo: .body))
                        .foregroundStyle(Theme.ink)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .background(Theme.paper)
        .navigationTitle(chapterTitle(chapter))
        .navigationBarTitleDisplayMode(.inline)
    }
}
