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
    @AppStorage("editorZoom") private var editorZoom = 100
    @AppStorage("editorLayout") private var editorLayout = EditorLayout.a4
    @AppStorage("editorSpellLanguage") private var editorSpellLanguage = "de"

    private var chapterIndex: Int? { editor.book.chapters.firstIndex { $0.id == chapterId } }

    var body: some View {
        Group {
            if chapterIndex != nil {
                LLMAssistantHost(
                    editor: editor,
                    isPresented: $showingLLM,
                    defaultScope: [ContentScopeItem(kind: .chapter, id: chapterId)],
                    title: currentChapterTitle
                ) {
                    editorBody
                }
            } else {
                EmptyStateView(systemImage: "doc.text.badge.xmark", title: String(localized: "Chapter removed"), message: String(localized: "This chapter no longer exists."))
            }
        }
    }

    private var editorBody: some View {
        VStack(spacing: 0) {
            FormatToolbar(controller: richTextController)
            EditorChromeBar(zoom: $editorZoom, layout: $editorLayout, spellLanguage: $editorSpellLanguage)
            RichTextView(attributedText: $attributedText, selectedRange: $selectedRange, controller: richTextController, zoomPercent: editorZoom, spellLanguage: editorSpellLanguage)
                .onChange(of: attributedText) { _, newValue in scheduleSave(newValue) }
                .frame(maxWidth: editorLayout.maxWidth)
                .frame(maxWidth: .infinity)
                .background(Color(uiColor: .systemGroupedBackground))
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

                LLMAssistantButton(isPresented: $showingLLM)
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
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: UTType(filenameExtension: "docx") ?? .data,
            defaultFilename: exportFilename
        ) { _ in }
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

/// Page-width simulation to match app.js's `teLayout` (app.js:308,
/// 2695-2697): A5 constrains the editor to a narrower reading column, A4
/// is full width. Purely a `maxWidth` on the text view — there's no
/// pagination on either platform, just a visual width cue.
enum EditorLayout: String, CaseIterable {
    case a4 = "A4"
    case a5 = "A5"

    var maxWidth: CGFloat? {
        switch self {
        case .a4: return nil
        case .a5: return 520
        }
    }
}

/// Mirrors app.js's `te-editor-toolbar-extra` row (app.js:2694-2707):
/// layout (A4/A5), spell-check language (DE/EN), and zoom (50–200%, ±10
/// per tap, matching `teZoomIn`/`teZoomOut`, app.js:1719-1727).
private struct EditorChromeBar: View {
    @Binding var zoom: Int
    @Binding var layout: EditorLayout
    @Binding var spellLanguage: String

    var body: some View {
        HStack(spacing: 14) {
            Picker("Layout", selection: $layout) {
                ForEach(EditorLayout.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 110)

            Picker("Spelling", selection: $spellLanguage) {
                Text("DE").tag("de")
                Text("EN").tag("en")
            }
            .pickerStyle(.segmented)
            .frame(width: 90)

            Spacer()

            HStack(spacing: 4) {
                Button {
                    zoom = max(50, zoom - 10)
                } label: { Image(systemName: "minus.circle") }
                Text("\(zoom)%").font(.caption).foregroundStyle(.secondary).frame(minWidth: 36)
                Button {
                    zoom = min(200, zoom + 10)
                } label: { Image(systemName: "plus.circle") }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
