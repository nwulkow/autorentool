import SwiftUI

/// Mirrors app.js's chapter list + "add chapter" flow (app.js:1427-1434).
struct ChapterListView: View {
    @ObservedObject var editor: BookEditor
    @State private var showingAdd = false

    var body: some View {
        Group {
            if editor.book.chapters.isEmpty {
                EmptyStateView(
                    systemImage: "doc.text",
                    title: "No chapters yet.",
                    message: "Start writing by adding your first chapter.",
                    actionTitle: "+ Add Chapter"
                ) { showingAdd = true }
            } else {
                List {
                    Section {
                        NavigationLink {
                            FullTextView(editor: editor)
                        } label: {
                            Label("Full text", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                    Section("Chapters") {
                        ForEach(editor.book.chapters) { chapter in
                            NavigationLink {
                                ChapterEditorView(editor: editor, chapterId: chapter.id)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(chapter.name.isEmpty ? chapter.label : chapter.name).font(.headline)
                                    if !chapter.name.isEmpty {
                                        Text(chapter.label).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .onMove { indices, newOffset in
                            editor.book.chapters.move(fromOffsets: indices, toOffset: newOffset)
                        }
                        .onDelete { indexSet in
                            editor.book.chapters.remove(atOffsets: indexSet)
                        }
                    }
                }
                .toolbar { EditButton() }
            }
        }
        .navigationTitle("Editor")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: { Label("Add Chapter", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddChapterSheet(editor: editor)
        }
    }
}

private struct AddChapterSheet: View {
    @ObservedObject var editor: BookEditor
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Chapter number / label", text: $label)
                TextField("Title (optional)", text: $name)
            }
            .navigationTitle("New Chapter")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        editor.book.chapters.append(Chapter(label: label.trimmingCharacters(in: .whitespaces), name: name.trimmingCharacters(in: .whitespaces)))
                        dismiss()
                    }
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
