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
        VStack(spacing: 0) {
            header
            content
        }
        .background(Theme.paper)
        .navigationTitle("Text")
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

    /// In-body header: a tab child's `.toolbar` doesn't merge into the
    /// shared nav bar (see `ios/README-iOS.md`), so the import/export menu
    /// lives here rather than silently never rendering.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Manuscript")
                .font(Theme.sectionTitle)
                .foregroundStyle(Theme.ink)
            Spacer()
            Menu {
                Button { showingImporter = true } label: { Label("Import File", systemImage: "square.and.arrow.down") }
                Button { exportBookDocx() } label: { Label("Export DOCX", systemImage: "square.and.arrow.up") }
                    .disabled(editor.book.chapters.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(Theme.chrome)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line), alignment: .bottom)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if editor.book.chapters.isEmpty {
                EmptyStateView(
                    systemImage: "doc.text",
                    title: String(localized: "No chapters yet."),
                    message: String(localized: "Start writing by adding your first chapter."),
                    actionTitle: String(localized: "+ Add Chapter")
                ) { showingAdd = true }
            } else {
                List {
                    NavigationLink {
                        FullTextView(editor: editor)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Full text")
                                    .font(Theme.rowTitle)
                                    .foregroundStyle(Theme.ink)
                                Text("\(editor.book.chapters.count) chapters")
                                    .font(.caption)
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                        .bookCard(padding: 14)
                    }
                    .bookCardRow()

                    ForEach(Array(editor.book.chapters.enumerated()), id: \.element.id) { index, chapter in
                        NavigationLink {
                            ChapterEditorView(editor: editor, chapterId: chapter.id)
                        } label: {
                            ChapterRow(index: index, chapter: chapter)
                        }
                        .bookCardRow()
                        .swipeActions(edge: .leading) {
                            Button {
                                exportChapterDocx(chapter, index: index)
                            } label: {
                                Label("Export DOCX", systemImage: "square.and.arrow.up")
                            }
                            .tint(Theme.accent)
                        }
                    }
                    .onMove { indices, newOffset in
                        editor.book.chapters.move(fromOffsets: indices, toOffset: newOffset)
                    }
                    .onDelete { indexSet in
                        editor.book.chapters.remove(atOffsets: indexSet)
                    }
                }
                .listStyle(.plain)
                .paperBackground()
                .safeAreaInset(edge: .bottom) {
                    AddBarButton(title: String(localized: "Add Chapter")) { showingAdd = true }
                }
            }
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

/// Mirrors `.te-ch-item` (app.js:2669-2681): a numbered spine, the label,
/// the optional title, and a word count.
private struct ChapterRow: View {
    let index: Int
    let chapter: Chapter

    var body: some View {
        HStack(spacing: 14) {
            Text("\(index + 1)")
                .font(Theme.serif(17, relativeTo: .headline).weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Theme.accentSoft, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.name.isEmpty ? chapter.label : chapter.name)
                    .font(Theme.rowTitle)
                    .foregroundStyle(Theme.ink)
                HStack(spacing: 6) {
                    if !chapter.name.isEmpty {
                        Text(chapter.label)
                        Text("·")
                    }
                    Text("\(wordCount) words")
                }
                .font(.caption)
                .foregroundStyle(Theme.muted)
            }
        }
        .bookCard(padding: 14)
    }

    /// Mirrors `wordCount` (app.js:1744-1748) — strip tags, split on
    /// whitespace.
    private var wordCount: Int {
        PromptBuilder.chapterPlainText(chapter)
            .split(whereSeparator: { $0.isWhitespace })
            .count
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
