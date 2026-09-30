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
    @EnvironmentObject private var env: AppEnvironment
    @State private var confirmingRebuildAll = false
    /// The chapter whose summary is open for reading/editing. Regenerating a
    /// single chapter happens in there, not from the row badge, so a stray
    /// tap can't replace text the user wrote.
    @State private var editingDigest: DigestTarget?

    var body: some View {
        VStack(spacing: 0) {
            header
            if env.digestService.progress != nil {
                DigestProgressBar(service: env.digestService)
            }
            content
        }
        .background(Theme.paper)
        .navigationTitle("Text")
        .confirmationDialog(
            "Generate summaries for all chapters?",
            isPresented: $confirmingRebuildAll,
            titleVisibility: .visible
        ) {
            Button("Generate \(pendingDigestCount) summaries") {
                env.digestService.generateAll(in: editor.book)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each chapter is sent to the model once. You can keep working while it runs, and anything already finished is kept if you stop it.")
        }
        .sheet(item: $editingDigest) { target in
            DigestEditorSheet(
                store: env.digestService.store(for: editor.book.title),
                service: env.digestService,
                editor: editor,
                index: target.index,
                chapter: target.chapter
            )
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
                Divider()
                Button { confirmingRebuildAll = true } label: {
                    Label("Generate all summaries", systemImage: "sparkles.rectangle.stack")
                }
                .disabled(pendingDigestCount == 0 || env.digestService.isRunning)
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
                                // The whole-book total the web app shows under
                                // the editor (app.js:3135).
                                Text("\(editor.book.chapters.count) chapters · \(totalWordCount.formatted()) words")
                                    .font(.caption)
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                        .bookCard(padding: 14)
                    }
                    .bookCardRow()

                    NavigationLink {
                        DigestListView(editor: editor)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "list.bullet.rectangle")
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Summaries")
                                    .font(Theme.rowTitle)
                                    .foregroundStyle(Theme.ink)
                                Text("\(digestedCount) of \(editor.book.chapters.count) chapters summarized")
                                    .font(.caption)
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                        .bookCard(padding: 14)
                    }
                    .bookCardRow()

                    ForEach(Array(editor.book.chapters.enumerated()), id: \.element.id) { index, chapter in
                        // The digest button is a sibling of the
                        // `NavigationLink`, not part of its label: a button
                        // inside a link's label never receives its own taps.
                        // That means the card treatment moves from the row
                        // to this `HStack`, so the button still sits inside
                        // the card rather than beside it.
                        HStack(spacing: 8) {
                            NavigationLink {
                                ChapterEditorView(editor: editor, chapterId: chapter.id)
                            } label: {
                                ChapterRow(index: index, chapter: chapter)
                            }
                            ChapterDigestButton(
                                store: env.digestService.store(for: editor.book.title),
                                service: env.digestService,
                                chapter: chapter
                            ) { status in
                                if status == .missing {
                                    env.digestService.generate(chapter: chapter, index: index, in: editor.book)
                                } else {
                                    editingDigest = DigestTarget(index: index, chapter: chapter)
                                }
                            }
                        }
                        .bookCard(padding: 14)
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

    /// Mirrors `totalWordCount` (app.js:2165-2167) — the web app's
    /// whole-book figure, which the phone was missing.
    private var totalWordCount: Int {
        editor.book.chapters.reduce(0) { $0 + $1.wordCount }
    }

    private var digestedCount: Int {
        let store = env.digestService.store(for: editor.book.title)
        return editor.book.chapters.filter { store.digest(for: $0.id) != nil }.count
    }

    /// Chapters with no digest or an out-of-date one. Hand-edited digests are
    /// excluded even when stale — a bulk run must never discard the user's
    /// own writing without being asked.
    private var pendingDigestCount: Int {
        env.digestService.store(for: editor.book.title).needingGeneration(in: editor.book).count
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
                    Text("\(chapter.wordCount) words")
                }
                .font(.caption)
                .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

extension Chapter {
    /// Mirrors `wordCount` (app.js:1744-1748) — strip tags, split on
    /// whitespace.
    var wordCount: Int {
        PromptBuilder.chapterPlainText(self)
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
