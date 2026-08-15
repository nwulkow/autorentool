import SwiftUI
import UniformTypeIdentifiers

/// Mirrors app.js's chapter list + "add chapter" flow (app.js:1427-1434),
/// plus the file import / whole-book DOCX export controls that live in
/// app.js's editor toolbar (app.js:2641-2643) — `triggerFileImport` and
/// `exportFullTextDocx`.
struct ChapterListView: View {
    @ObservedObject var editor: BookEditor
    @State private var showingAdd = false
    @State private var exportDocument: DocxFileDocument?
    @State private var showingExporter = false
    @State private var exportFilename = "book.docx"
    @State private var showingImporter = false
    @State private var importErrorMessage: String?

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
                        ForEach(Array(editor.book.chapters.enumerated()), id: \.element.id) { index, chapter in
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
                            .swipeActions(edge: .leading) {
                                Button {
                                    exportChapterDocx(chapter, index: index)
                                } label: {
                                    Label("Export DOCX", systemImage: "square.and.arrow.up")
                                }
                                .tint(.blue)
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
                Menu {
                    Button { showingImporter = true } label: { Label("Import File", systemImage: "square.and.arrow.down") }
                    Button { exportBookDocx() } label: { Label("Export DOCX", systemImage: "square.and.arrow.up") }
                        .disabled(editor.book.chapters.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: { Label("Add Chapter", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddChapterSheet(editor: editor)
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: UTType(filenameExtension: "docx") ?? .data,
            defaultFilename: exportFilename
        ) { _ in }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "docx") ?? .data,
                UTType(filenameExtension: "doc") ?? .data,
                .plainText,
            ]
        ) { result in
            handleImport(result)
        }
        .alert("Import failed!", isPresented: Binding(get: { importErrorMessage != nil }, set: { if !$0 { importErrorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "")
        }
    }

    private func exportChapterDocx(_ chapter: Chapter, index: Int) {
        exportFilename = DocxExporter.filename(forChapter: chapter)
        exportDocument = DocxFileDocument(data: DocxExporter.exportChapter(chapter, index: index))
        showingExporter = true
    }

    private func exportBookDocx() {
        exportFilename = DocxExporter.filename(forBook: editor.book.title)
        exportDocument = DocxFileDocument(data: DocxExporter.exportFullText(chapters: editor.book.chapters))
        showingExporter = true
    }

    /// Mirrors `handleFileImport` (app.js:1871-1900): create a new chapter
    /// from the imported file and select it.
    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure:
            importErrorMessage = "Import failed!"
        case .success(let url):
            do {
                let (label, html) = try DocxImporter.importChapter(from: url)
                let chapter = Chapter(label: label, content: html)
                editor.book.chapters.append(chapter)
            } catch DocxImporter.ImportError.legacyDocUnsupported {
                importErrorMessage = "Legacy .doc files aren't supported — please convert to .docx first."
            } catch {
                importErrorMessage = "Import failed!"
            }
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
