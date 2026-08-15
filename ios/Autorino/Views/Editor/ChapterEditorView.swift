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
    /// The text exactly as loaded, plus whether it has since been edited.
    /// Re-exporting an untouched chapter is not a no-op — the HTML that
    /// comes back out is this platform's, not Quill's — so merely opening a
    /// chapter used to rewrite it and mark the book dirty for Dropbox. The
    /// flag makes "no edits" mean "no write".
    @State private var loadedText = NSAttributedString(string: "")
    @State private var hasEdits = false
    @State private var showingComments = false
    @State private var showingAddComment = false
    @State private var showingPassages = false
    @State private var showingLLM = false
    @State private var exportDocument: DocxFileDocument?
    @State private var showingExporter = false
    @AppStorage("editorZoom") private var editorZoom = EditorZoom.default
    @AppStorage("editorZoomBaseVersion") private var editorZoomBaseVersion = 0
    /// `"auto"` means "not chosen yet" — resolved to the device's own
    /// writing language on first open, so spell checking is on out of the
    /// box for whoever's writing.
    @AppStorage("editorSpellLanguage") private var editorSpellLanguage = "auto"
    @Environment(\.scenePhase) private var scenePhase

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
            FormatToolbar(controller: richTextController, zoom: $editorZoom)
            page
        }
        .background(Theme.paper)
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
                    spellCheckMenu
                    Button { exportDocx() } label: { Label("Export DOCX", systemImage: "square.and.arrow.up") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }

                LLMAssistantButton(isPresented: $showingLLM)
            }
        }
        .onAppear {
            migratePreferences()
            loadContent()
        }
        .onDisappear { save() }
        // Leaving the app is the one moment the debounced autosave can't
        // cover on its own — see `save()`.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { save() }
        }
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

    /// The writing surface, on a page. Phone width fills edge to edge; on
    /// anything wider the column stops at a readable measure and the warm
    /// paper ground shows around it — which is the useful half of what the
    /// A4/A5 picker was reaching for, minus a control that couldn't change
    /// anything on a phone.
    private var page: some View {
        RichTextView(
            attributedText: $attributedText,
            selectedRange: $selectedRange,
            controller: richTextController,
            zoomPercent: editorZoom,
            spellLanguage: SpellCheck.resolved(editorSpellLanguage)
        )
        .onChange(of: attributedText) { _, newValue in scheduleSave(newValue) }
        .background(Theme.panel)
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 1)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }

    /// Every entry here is a dictionary `UITextChecker` actually has on this
    /// device (`SpellCheck.availableLanguages`), so unlike the DE/EN pair it
    /// replaces, picking one always changes what gets flagged.
    private var spellCheckMenu: some View {
        Menu {
            Picker("Spell check", selection: $editorSpellLanguage) {
                Text("Off").tag("")
                ForEach(SpellCheck.availableLanguages, id: \.self) { code in
                    Text(SpellCheck.displayName(for: code)).tag(code)
                }
            }
        } label: {
            Label("Spell check", systemImage: "text.magnifyingglass")
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

    /// Both editor preferences changed meaning in this version, so both get
    /// resolved once rather than being read literally forever: a zoom stored
    /// against the old 12pt baseline would now render far larger than it
    /// did, and the old `"de"`/`"en"` spell values aren't `UITextChecker`
    /// language identifiers.
    private func migratePreferences() {
        if editorZoomBaseVersion < EditorZoom.baseVersion {
            editorZoom = EditorZoom.default
            editorZoomBaseVersion = EditorZoom.baseVersion
        } else {
            editorZoom = EditorZoom.snapped(editorZoom)
        }

        if editorSpellLanguage == "auto" {
            editorSpellLanguage = SpellCheck.deviceDefault
        } else if !editorSpellLanguage.isEmpty {
            editorSpellLanguage = SpellCheck.resolved(editorSpellLanguage) ?? SpellCheck.off
        }
    }

    private func loadContent() {
        guard let index = chapterIndex else { return }
        let loaded = HTMLConversion.attributedString(fromHTML: editor.book.chapters[index].content)
        loadedText = loaded
        hasEdits = false
        attributedText = loaded
    }

    private func scheduleSave(_ newValue: NSAttributedString) {
        // One comparison until the document first differs from what was
        // loaded, then none — after that every change is an edit by
        // definition.
        if !hasEdits {
            guard !newValue.isEqual(loadedText) else { return }
            hasEdits = true
        }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            commit(newValue)
        }
    }

    /// Flushes both debounces at once: the 0.8s one above that turns the
    /// attributed string back into the chapter's HTML, and `BookEditor`'s
    /// 1.5s one that writes the book to disk. Without this, leaving the app
    /// straight after a keystroke could drop the last couple of seconds of
    /// typing, since neither timer survives the process going away.
    private func save() {
        saveTask?.cancel()
        guard hasEdits else { return }
        commit(attributedText)
        editor.saveNow()
    }

    private func commit(_ attributed: NSAttributedString) {
        guard let index = chapterIndex else { return }
        let html = HTMLConversion.html(from: attributed)
        guard editor.book.chapters[index].content != html else { return }
        editor.book.chapters[index].content = html
    }

    private var exportFilename: String {
        guard let index = chapterIndex else { return "chapter.docx" }
        return DocxExporter.filename(forChapter: editor.book.chapters[index])
    }

    private func exportDocx() {
        guard let index = chapterIndex else { return }
        save()
        let chapter = editor.book.chapters[index]
        exportDocument = DocxFileDocument(data: DocxExporter.exportChapter(chapter, index: index))
        showingExporter = true
    }
}
