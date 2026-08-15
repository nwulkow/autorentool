import SwiftUI
import UniformTypeIdentifiers

/// The chapter writing surface — `RichTextView` + `FormatToolbar` replace
/// Quill (app.js:1468-1528); comments/passages/LLM assistant are reachable
/// from the toolbar instead of a permanently-docked side panel (see
/// `LLMAssistantSheet` and `docs/migration-architecture.md` §5-6 for why).
struct ChapterEditorView: View {
    @ObservedObject var editor: BookEditor
    let chapterId: String

    @StateObject private var richTextController = RichTextController()
    @State private var attributedText = NSAttributedString(string: "")
    @State private var selectedRange = NSRange(location: 0, length: 0)
    @State private var saveTask: Task<Void, Never>?
    @State private var showingComments = false
    @State private var showingAddComment = false
    @State private var showingPassages = false
    @State private var showingLLM = false
    @State private var exportDocument: DocxFileDocument?
    @State private var showingExporter = false

    private var chapterIndex: Int? { editor.book.chapters.firstIndex { $0.id == chapterId } }

    var body: some View {
        Group {
            if chapterIndex != nil {
                VStack(spacing: 0) {
                    FormatToolbar(controller: richTextController)
                    RichTextView(attributedText: $attributedText, selectedRange: $selectedRange, controller: richTextController)
                        .onChange(of: attributedText) { _, newValue in scheduleSave(newValue) }
                }
                .navigationTitle(currentChapterTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            showingAddComment = true
                        } label: {
                            Label("Comment", systemImage: "text.bubble")
                        }
                        .disabled(selectedRange.length == 0)

                        Menu {
                            Button { showingComments = true } label: { Label("Comments", systemImage: "text.bubble") }
                            Button { showingPassages = true } label: { Label("Passages", systemImage: "scissors") }
                            Button { exportDocx() } label: { Label("Export DOCX", systemImage: "square.and.arrow.up") }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }

                        LLMAssistantButton { showingLLM = true }
                    }
                }
                .onAppear(perform: loadContent)
                .onDisappear { commitNow() }
                .sheet(isPresented: $showingComments) {
                    CommentsListView(comments: commentsBinding)
                }
                .sheet(isPresented: $showingAddComment) {
                    AddCommentSheet(
                        comments: commentsBinding,
                        selection: selectedText,
                        rangeIndex: selectedRange.location,
                        rangeLength: selectedRange.length
                    )
                }
                .sheet(isPresented: $showingPassages) {
                    PassagesSheet(editor: editor, chapterId: chapterId)
                }
                .sheet(isPresented: $showingLLM) {
                    LLMAssistantSheet(editor: editor, defaultScope: [ContentScopeItem(kind: .chapter, id: chapterId)])
                }
                .fileExporter(
                    isPresented: $showingExporter,
                    document: exportDocument,
                    contentType: UTType(filenameExtension: "docx") ?? .data,
                    defaultFilename: exportFilename
                ) { _ in }
            } else {
                EmptyStateView(systemImage: "doc.text.badge.xmark", title: String(localized: "Chapter removed"), message: String(localized: "This chapter no longer exists."))
            }
        }
    }

    private var currentChapterTitle: String {
        guard let index = chapterIndex else { return "" }
        let chapter = editor.book.chapters[index]
        return chapter.name.isEmpty ? chapter.label : chapter.name
    }

    private var commentsBinding: Binding<[Comment]> {
        Binding(
            get: { chapterIndex.map { editor.book.chapters[$0].comments } ?? [] },
            set: { newValue in if let index = chapterIndex { editor.book.chapters[index].comments = newValue } }
        )
    }

    private var selectedText: String {
        guard selectedRange.location != NSNotFound, selectedRange.length > 0,
              selectedRange.location + selectedRange.length <= attributedText.length else { return "" }
        return attributedText.attributedSubstring(from: selectedRange).string
    }

    private func loadContent() {
        guard let index = chapterIndex else { return }
        attributedText = HTMLConversion.attributedString(fromHTML: editor.book.chapters[index].content)
    }

    private func scheduleSave(_ newValue: NSAttributedString) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            commit(newValue)
        }
    }

    private func commitNow() {
        saveTask?.cancel()
        commit(attributedText)
    }

    private func commit(_ attributed: NSAttributedString) {
        guard let index = chapterIndex else { return }
        editor.book.chapters[index].content = HTMLConversion.html(from: attributed)
    }

    private var exportFilename: String {
        guard let index = chapterIndex else { return "chapter.docx" }
        return DocxExporter.filename(forChapter: editor.book.chapters[index])
    }

    private func exportDocx() {
        guard let index = chapterIndex else { return }
        commitNow()
        let chapter = editor.book.chapters[index]
        exportDocument = DocxFileDocument(data: DocxExporter.exportChapter(chapter, index: index))
        showingExporter = true
    }
}
