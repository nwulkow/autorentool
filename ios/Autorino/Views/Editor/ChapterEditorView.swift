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
    /// The alternative version open in the editor; `nil` = main (V1). See
    /// `ChapterVersion` and docs/chapter-versions-plan.md.
    @State private var versionId: String?
    /// The slot `loadContent()` read from — commits always go back there,
    /// even if `versionId` has moved on (same job as app.js's
    /// `_quillVersionId`).
    @State private var loadedSlot: String?
    @State private var showingNewVersion = false
    @State private var showingRenameVersion = false
    @State private var renameText = ""
    @State private var showingDeleteVersion = false
    /// Set by "Compare with main" for the next assistant session only.
    @State private var compareScope: [ContentScopeItem]?
    @State private var assistantPrompt = ""
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
                    defaultScope: assistantScope,
                    title: currentChapterTitle,
                    contextChapterId: chapterId,
                    initialPrompt: assistantPrompt
                ) {
                    editorBody
                }
                .onChange(of: showingLLM) { _, open in
                    if !open { compareScope = nil; assistantPrompt = "" }
                }
            } else {
                EmptyStateView(systemImage: "doc.text.badge.xmark", title: String(localized: "Chapter removed"), message: String(localized: "This chapter no longer exists."))
            }
        }
    }

    private var editorBody: some View {
        VStack(spacing: 0) {
            FormatToolbar(controller: richTextController, zoom: $editorZoom)
            if versionId != nil { versionBanner }
            page
        }
        .background(Theme.paper)
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    richTextController.presentFind()
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }

                Button {
                    showingAddComment = true
                } label: {
                    Label("Comment", systemImage: "text.bubble")
                }
                .disabled(selectedRange.length == 0)

                Menu {
                    versionsMenu
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
            PassagesSheet(editor: editor, chapterId: chapterId, fromAlternativeVersion: versionId != nil)
        }
        .sheet(isPresented: $showingNewVersion) {
            if let chapter {
                NewVersionSheet(chapter: chapter) { source, name in createVersion(from: source, name: name) }
            }
        }
        .alert("Rename version", isPresented: $showingRenameVersion) {
            TextField("Name (optional)", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { renameVersion() }
        }
        .confirmationDialog(
            String(format: String(localized: "Delete version %@?"), chapter?.versionLabel(slot: versionId) ?? ""),
            isPresented: $showingDeleteVersion,
            titleVisibility: .visible
        ) {
            Button("Delete version", role: .destructive) { deleteVersion() }
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

    private var chapter: Chapter? { chapterIndex.map { editor.book.chapters[$0] } }

    private var navigationTitleText: String {
        guard let chapter, versionId != nil else { return currentChapterTitle }
        return "\(currentChapterTitle) · V\(chapter.versionNumber(slot: versionId))"
    }

    private var assistantScope: [ContentScopeItem] {
        if let compareScope { return compareScope }
        if let versionId { return [ContentScopeItem(kind: .version, id: versionId)] }
        return [ContentScopeItem(kind: .chapter, id: chapterId)]
    }

    // MARK: - Versions

    private var versionSelection: Binding<String?> {
        Binding(get: { versionId }, set: { switchVersion(to: $0) })
    }

    @ViewBuilder
    private var versionsMenu: some View {
        if let chapter {
            Menu {
                if !chapter.versions.isEmpty {
                    Picker("Version", selection: versionSelection) {
                        Text(chapter.versionLabel(slot: nil) + " (" + String(localized: "main") + ")").tag(String?.none)
                        ForEach(chapter.versions) { version in
                            Text(chapter.versionLabel(slot: version.id)).tag(Optional(version.id))
                        }
                    }
                }
                Button { showingNewVersion = true } label: { Label("New version…", systemImage: "plus") }
                if versionId != nil {
                    Button { makeMain() } label: { Label("Make main version", systemImage: "arrow.left.arrow.right") }
                    Button { compareWithMain() } label: { Label("Compare with main", systemImage: "sparkles") }
                }
                if versionId != nil || !chapter.versions.isEmpty {
                    Button {
                        renameText = chapter.versionName(slot: versionId)
                        showingRenameVersion = true
                    } label: { Label("Rename version…", systemImage: "pencil") }
                }
                if versionId != nil {
                    Button(role: .destructive) { showingDeleteVersion = true } label: { Label("Delete version", systemImage: "trash") }
                }
            } label: {
                Label("Versions", systemImage: "square.stack")
            }
        }
    }

    /// Body content rather than a toolbar item, so it is always visible
    /// while an alternative is being edited.
    private var versionBanner: some View {
        HStack(spacing: 8) {
            if let chapter {
                Text("Editing \(chapter.versionLabel(slot: versionId)) · \(Self.wordCount(attributedText.string)) words · not counted")
                    .font(.caption)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("Make main") { makeMain() }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Theme.accentSoft)
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private func switchVersion(to id: String?) {
        guard id != versionId else { return }
        save()
        versionId = id
        loadContent()
    }

    private func createVersion(from source: Chapter.VersionSource, name: String) {
        guard let index = chapterIndex else { return }
        save()
        let id = editor.book.chapters[index].createVersion(from: source, name: name)
        versionId = id
        loadContent()
    }

    /// Swaps the open version into main; the user then sees it as V1.
    private func makeMain() {
        guard let index = chapterIndex, let id = versionId else { return }
        save()
        editor.book.chapters[index].swapWithMain(id)
        versionId = nil
        loadContent()
    }

    private func renameVersion() {
        guard let index = chapterIndex else { return }
        editor.book.chapters[index].renameVersion(slot: versionId, to: renameText.trimmingCharacters(in: .whitespaces))
    }

    /// The save that follows sees fewer versions, so `BookStore` snapshots
    /// the book before writing (`BackupStore.bookShrank`).
    private func deleteVersion() {
        guard let index = chapterIndex, let id = versionId else { return }
        save()
        editor.book.chapters[index].deleteVersion(id)
        versionId = nil
        loadContent()
    }

    private func compareWithMain() {
        guard let chapter, let id = versionId else { return }
        save()
        compareScope = [ContentScopeItem(kind: .chapter, id: chapterId), ContentScopeItem(kind: .version, id: id)]
        assistantPrompt = String(format: String(localized: "Compare version 1 and version %lld of this chapter: differences in plot, tone, pacing and characterization, and the strengths and weaknesses of each."), chapter.versionNumber(slot: id))
        showingLLM = true
    }

    private var currentChapterTitle: String {
        guard let index = chapterIndex else { return "" }
        let chapter = editor.book.chapters[index]
        return chapter.name.isEmpty ? chapter.label : chapter.name
    }

    private var commentsBinding: Binding<[Comment]> {
        Binding(
            get: { chapterIndex.map { editor.book.chapters[$0].comments(slot: versionId) } ?? [] },
            set: { newValue in if let index = chapterIndex { editor.book.chapters[index].setComments(newValue, slot: versionId) } }
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
        // A version deleted elsewhere (sync) falls back to main.
        if let id = versionId, editor.book.chapters[index].version(id) == nil { versionId = nil }
        loadedSlot = versionId
        let loaded = HTMLConversion.attributedString(fromHTML: editor.book.chapters[index].content(slot: versionId))
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
        guard editor.book.chapters[index].content(slot: loadedSlot) != html else { return }
        editor.book.chapters[index].setContent(html, slot: loadedSlot)
    }

    private var exportFilename: String {
        guard let index = chapterIndex else { return "chapter.docx" }
        let chapter = editor.book.chapters[index]
        let name = DocxExporter.filename(forChapter: chapter)
        guard versionId != nil else { return name }
        return String(name.dropLast(".docx".count)) + " (V\(chapter.versionNumber(slot: versionId))).docx"
    }

    private func exportDocx() {
        guard let index = chapterIndex else { return }
        save()
        // The open version is what gets exported.
        var chapter = editor.book.chapters[index]
        chapter.content = chapter.content(slot: versionId)
        exportDocument = DocxFileDocument(data: DocxExporter.exportChapter(chapter, index: index))
        showingExporter = true
    }
}
