import SwiftUI

/// The LLM chat surface. app.js docks this in a permanent side panel next
/// to the editor (fine on desktop, unusable on a ~390pt-wide phone). Here
/// it adapts to size class: a bottom-sheet drawer on compact width
/// (`.medium`, draggable to `.large`), a `NavigationSplitView` trailing
/// column on regular width (iPad, Mac Catalyst) so it can stay open
/// alongside the content it's discussing, matching app.js's own permanent
/// side panel there. See `docs/migration-architecture.md` §6/§6.5 for the
/// full rationale.
///
/// `persist` selects between the shared per-book transcript
/// (`ChatHistoryStore`, app.js's default `persist:true` pane) and an
/// ephemeral view-local history (`persist:false`, e.g. the event-order
/// assistant's `runEoLlmPrompt`, app.js:516-545) that doesn't survive
/// dismissing the sheet. `baseContext`, when set, is prepended to every
/// outgoing prompt but never shown as its own chat bubble — mirrors
/// `runEoLlmPrompt`'s `text` (the event-order dump) being sent alongside
/// the user's `custom_prompt` on every turn.
struct LLMAssistantSheet: View {
    @ObservedObject var editor: BookEditor
    var defaultScope: [ContentScopeItem] = []
    var persist = true
    var baseContext: String?
    var title: String = String(localized: "Assistant")
    var contextChapterId: String?

    var body: some View {
        NavigationStack {
            LLMAssistantContent(editor: editor, defaultScope: defaultScope, persist: persist, baseContext: baseContext, title: title, contextChapterId: contextChapterId)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// The chat UI itself, factored out of `LLMAssistantSheet` so the same
/// surface can also sit in a `NavigationSplitView` trailing column on
/// regular width (see `LLMAssistantSplitContainer`) without duplicating
/// the message list/input bar/history wiring.
struct LLMAssistantContent: View {
    @ObservedObject var editor: BookEditor
    var defaultScope: [ContentScopeItem] = []
    var persist = true
    var baseContext: String?
    var title: String = String(localized: "Assistant")
    /// The chapter this chat is anchored to, used only to stamp a saved chat
    /// with the chapter number/label it was about. `nil` for panes that
    /// aren't chapter-scoped (the event-order assistant), which then fall
    /// back to whatever chapter the scope picker has selected.
    var contextChapterId: String?

    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var persistedHistory: ChatHistoryStore
    @State private var localMessages: [ChatMessage] = []
    @State private var scope: [ContentScopeItem]
    @State private var prompt = ""
    @State private var isLoading = false
    @State private var error: String?
    /// Persisted across sessions and shared by every assistant pane (chapter
    /// chat, event-order chat) — one pick for the whole app, matching
    /// app.js's single `llmSelectedModel`.
    @AppStorage("geminiSelectedModel") private var selectedModel: String = GeminiModelCatalog.defaultModel
    @State private var availableModels: [String] = GeminiModelCatalog.staticModels
    /// Persisted and shared by every assistant pane, same as the model pick.
    /// `.auto` sends no `thinkingConfig` at all, which is what every call did
    /// before these controls existed.
    @AppStorage("geminiThinkingLevel") private var thinkingSetting: ThinkingSetting = .auto
    /// Gemini accepts 0...2, but the slider stops at 1.0 — its own default,
    /// and the top of the range that stays coherent for this use. Low for
    /// checking logic and facts, high for hunting ideas.
    @AppStorage("geminiTemperature") private var temperature: Double = 1.0

    /// A build before the slider was capped could have stored a value above
    /// the current range; the `Slider` would render it pinned but `@AppStorage`
    /// keeps — and would send — the old number.
    private var clampedTemperature: Double { min(max(temperature, 0), 1) }
    /// Set only when the server — here, Gemini directly — substituted a
    /// different model than the one picked above (busy, retired, out of
    /// quota); cleared on every new pick.
    @State private var modelUsed: String?
    /// Off means the next prompt goes out without the selected
    /// chapter/passage text — for follow-up questions that have nothing to do
    /// with the manuscript, where re-sending a chapter every turn is pure
    /// token cost. Characters (and a pane's own `baseContext`, e.g. an event
    /// dump) are unaffected; only book prose is dropped.
    @State private var includeBookText = true
    /// On by default, and the reason the digests exist: the whole book as
    /// notes costs roughly a tenth of the prose it stands in for, so there is
    /// no version of "ask about the book" that is better served by leaving it
    /// out. Off is for the follow-up turns that aren't about the manuscript.
    @State private var includeDigests = true
    /// Summaries held out of this chat. Empty — every stored summary goes —
    /// until the user unchecks one, which is the common case; the point of
    /// unchecking is usually to keep later chapters out of an answer about
    /// earlier ones, not to save tokens.
    @State private var excludedDigests: Set<String> = []
    /// Zero-based index of the last chapter whose summary goes out; `nil` is
    /// the whole book. This is what stops the model answering a chapter-8
    /// problem with something that only happens in chapter 19 — and the model
    /// is told the cutoff exists, so it doesn't mistake it for the ending.
    @State private var digestCutoff: Int?
    @State private var showingSavePrompt = false
    @State private var saveName = ""
    @State private var showingSavedChats = false
    /// The last prompt that went out and didn't come back with an answer.
    /// Held so "Retry" can re-send it verbatim — a failed turn used to lose
    /// the typed text entirely (`send` clears the field before the call), and
    /// with Gemini 3.x timing out on long chapters that happened often enough
    /// to be the single most annoying thing about the assistant.
    @State private var failedPrompt: String?

    init(editor: BookEditor, defaultScope: [ContentScopeItem] = [], persist: Bool = true, baseContext: String? = nil, title: String = String(localized: "Assistant"), contextChapterId: String? = nil) {
        self.editor = editor
        self.defaultScope = defaultScope
        self.persist = persist
        self.baseContext = baseContext
        self.title = title
        self.contextChapterId = contextChapterId
        _persistedHistory = StateObject(wrappedValue: ChatHistoryStore(bookTitle: editor.book.title))
        // Every character is in scope unless the caller picked its own set.
        // A cast of a dozen is a few hundred tokens, and without it the model
        // meets every name cold — the one thing that reliably makes an answer
        // useless is not knowing who it is talking about.
        var initialScope = defaultScope
        if !initialScope.contains(where: { $0.kind == .character }) {
            initialScope += editor.book.characters.map { ContentScopeItem(kind: .character, id: $0.id) }
        }
        _scope = State(initialValue: initialScope)
    }

    private var messages: [ChatMessage] { persist ? persistedHistory.messages : localMessages }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                modelPickerRow
                generationSettingsRow
                ContentScopePickerView(
                    book: editor.book,
                    selection: $scope,
                    digestChapters: digestChapters,
                    excludedDigests: $excludedDigests,
                    digestCutoff: digestCutoff
                )
                includeBookTextRow
            }
            .background(Theme.chrome)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line), alignment: .bottom)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty {
                            emptyState
                        }
                        ForEach(messages) { message in
                            ChatBubbleView(message: message).id(message.id)
                        }
                        if isLoading {
                            ChatTypingIndicator().id(Self.typingIndicatorID)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { _, _ in scrollToEnd(proxy) }
                .onChange(of: isLoading) { _, _ in scrollToEnd(proxy) }
            }
            if let error {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    // Only offered when there's a prompt to re-send — an
                    // error with nothing held (e.g. a failed model list)
                    // shouldn't show a button that would do nothing.
                    if failedPrompt != nil {
                        Button(action: retry) {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .disabled(isLoading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
            inputBar
        }
        .background(Theme.paper)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { beginSave() } label: { Label("Save chat", systemImage: "square.and.arrow.down") }
                        .disabled(messages.isEmpty)
                    Button { showingSavedChats = true } label: { Label("Load chat", systemImage: "clock.arrow.circlepath") }
                        .disabled(editor.book.savedChats.isEmpty)
                    Divider()
                    Button(role: .destructive) { clear() } label: { Label("Clear", systemImage: "trash") }
                        .disabled(messages.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Save chat", isPresented: $showingSavePrompt) {
            TextField("Name", text: $saveName)
            Button("Save") { saveChat() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keeps a copy of this conversation with the book, tagged with the chapter it was about.")
        }
        .sheet(isPresented: $showingSavedChats) {
            NavigationStack {
                SavedChatsListView(
                    savedChats: editor.book.savedChats,
                    onLoad: { chat in
                        load(chat)
                        showingSavedChats = false
                    },
                    onDelete: { chat in
                        editor.book.savedChats.removeAll { $0.id == chat.id }
                    }
                )
            }
        }
        .onAppear {
            if persist {
                let syncEngine = env.chatSyncEngine
                persistedHistory.onChange = { filename in
                    syncEngine.markDirty(filename: filename)
                }
                // Pull in whatever another device may have added since this
                // book's transcript was last opened here, same as book sync
                // catching up `BookStore` on launch.
                Task {
                    await syncEngine.sync()
                    persistedHistory.reload()
                }
            }
            // If the saved pick has since been retired, fall back to
            // whatever loads first rather than silently 404ing on send.
            Task {
                let models = await GeminiModelCatalog.fetchModels(apiKey: KeychainService.get(.geminiAPIKey))
                availableModels = models
                if !models.isEmpty, !models.contains(selectedModel) { selectedModel = models[0] }
            }
        }
    }

    /// Mirrors app.js's "Model" select in the LLM panel — one picker shared
    /// by every pane instantiating this view, persisted via `@AppStorage` so
    /// it carries over between panes and app launches.
    private var modelPickerRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Menu {
                ForEach(availableModels, id: \.self) { model in
                    Button {
                        selectedModel = model
                        modelUsed = nil
                    } label: {
                        if model == selectedModel {
                            Label(model, systemImage: "checkmark")
                        } else {
                            Text(model)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selectedModel)
                        .font(.footnote)
                        .foregroundStyle(Theme.ink)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                    Spacer()
                }
            }
            if let modelUsed {
                Text("Answered by \(modelUsed)")
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
                    .italic()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// How hard the model thinks, and how freely it samples — the two knobs
    /// that decide both answer character and wall-clock time, so they sit
    /// next to the model pick rather than behind a Settings screen. Thinking
    /// is a `Menu` (three discrete choices, one of which means "send
    /// nothing"); temperature is continuous, so it gets a slider.
    private var generationSettingsRow: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(ThinkingSetting.allCases, id: \.self) { setting in
                    Button {
                        thinkingSetting = setting
                    } label: {
                        if setting == thinkingSetting {
                            Label(setting.label, systemImage: "checkmark")
                        } else {
                            Text(setting.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                        .font(.system(size: 10, weight: .semibold))
                    Text(thinkingSetting.shortLabel)
                        .font(.caption)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }
                .foregroundStyle(Theme.ink)
            }
            .fixedSize()

            Divider().frame(height: 14)

            Image(systemName: "thermometer.medium")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.muted)
            Slider(value: $temperature, in: 0...1, step: 0.1)
            Text(String(format: "%.1f", clampedTemperature))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.muted)
                .frame(width: 22, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }

    /// Deliberately a plain checkbox row rather than a `Toggle` switch: it
    /// belongs to the same "what goes in the prompt" group as the scope
    /// picker's checkmarks directly above it, and reads as one list.
    /// Both context switches share one line: the sheet opens at the `.medium`
    /// detent, where every header row is taken off the transcript.
    private var includeBookTextRow: some View {
        HStack(spacing: 16) {
            contextToggle("Book text", isOn: $includeBookText, enabled: true)
            contextToggle("Summaries", isOn: $includeDigests, enabled: digestCount > 0)
            Spacer()
            if includeDigests, digestCount > 0 {
                digestRangeMenu
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func contextToggle(_ label: LocalizedStringKey, isOn: Binding<Bool>, enabled: Bool) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn.wrappedValue && enabled ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn.wrappedValue && enabled ? Color.accentColor : .secondary)
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(enabled ? Theme.ink : Theme.muted)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var digestCount: Int {
        env.digestService.store(for: editor.book.title).digests.count
    }

    /// Only chapters that have a summary — there is nothing to include or
    /// exclude for the rest, and listing them would just be 19 dead rows.
    private var digestChapters: [(id: String, label: String)] {
        let store = env.digestService.store(for: editor.book.title)
        return editor.book.chapters.compactMap { chapter in
            guard store.digest(for: chapter.id) != nil else { return nil }
            return (chapter.id, PromptBuilder.chapterDisplayName(chapter.id, in: editor.book.chapters))
        }
    }

    private var includedDigestCount: Int {
        digestEntries.count
    }

    /// The summaries this turn would actually carry: stored, not unchecked,
    /// and at or before the cutoff.
    private var digestEntries: [PromptBuilder.DigestContextEntry] {
        env.digestService.store(for: editor.book.title)
            .promptEntries(in: editor.book)
            .filter { !excludedDigests.contains($0.digest.chapterId) }
            .filter { entry in digestCutoff.map { entry.index <= $0 } ?? true }
    }

    @ViewBuilder
    private func menuItem(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isOn {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    /// The count doubles as the control: tapping it sets how far through the
    /// book the summaries reach. One tap instead of unchecking fifteen rows.
    private var digestRangeMenu: some View {
        Menu {
            menuItem(String(localized: "All chapters"), isOn: digestCutoff == nil) { digestCutoff = nil }
            if let contextChapterId,
               let index = editor.book.chapters.firstIndex(where: { $0.id == contextChapterId }) {
                menuItem(String(localized: "Up to this chapter"), isOn: digestCutoff == index) { digestCutoff = index }
            }
            Divider()
            ForEach(Array(editor.book.chapters.enumerated()), id: \.element.id) { index, chapter in
                menuItem(
                    String(format: String(localized: "Up to %@"), PromptBuilder.chapterDisplayName(chapter.id, in: editor.book.chapters)),
                    isOn: digestCutoff == index
                ) { digestCutoff = index }
            }
        } label: {
            HStack(spacing: 3) {
                Text("\(includedDigestCount)/\(editor.book.chapters.count)")
                Image(systemName: "chevron.up.chevron.down")
            }
            .font(.caption2)
            .foregroundStyle(digestCutoff == nil ? Theme.muted : Theme.accent)
        }
    }

    private static let typingIndicatorID = "typing"

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) {
            if isLoading {
                proxy.scrollTo(Self.typingIndicatorID, anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    /// An empty transcript is the assistant's first impression, so it opens
    /// with something to tap rather than a grey paragraph explaining itself.
    /// The starters fill the field instead of sending, so a prompt can still
    /// be adjusted before it goes.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 38, height: 38)
                    .background(Theme.accentSoft, in: Circle())
                    .overlay(Circle().stroke(Theme.line, lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Let's talk about your book")
                        .font(Theme.sectionTitle)
                        .foregroundStyle(Theme.ink)
                    Text("Add chapters, passages or characters above to give me more to work with.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.starters, id: \.self) { starter in
                    Button {
                        prompt = starter
                    } label: {
                        HStack(spacing: 8) {
                            Text(starter)
                                .font(.footnote)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(Theme.ink)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.accent)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                                .stroke(Theme.line, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private static let starters: [String] = [
        String(localized: "What's inconsistent or unclear?"),
        String(localized: "Is this chapter realistic?"),
        String(localized: "Does this character sound like themselves?"),
    ]

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message…", text: $prompt, axis: .vertical)
                .font(.callout)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Theme.line, lineWidth: 1)
                )

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(canSend ? Theme.accent : Theme.muted.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .animation(.easeOut(duration: 0.15), value: canSend)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.chrome)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line), alignment: .top)
    }

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
    }

    private func clear() {
        if persist { persistedHistory.clear() } else { localMessages = [] }
    }

    private func append(_ message: ChatMessage) {
        if persist { persistedHistory.append(message) } else { localMessages.append(message) }
    }

    private func remove(_ message: ChatMessage) {
        if persist {
            persistedHistory.remove(id: message.id)
        } else {
            localMessages.removeAll { $0.id == message.id }
        }
    }

    // MARK: - Saved chats

    /// The chapter a saved chat gets stamped with: the pane's own chapter if
    /// it has one, otherwise the first chapter picked in the scope list.
    private var anchorChapterId: String? {
        contextChapterId ?? scope.first { $0.kind == .chapter }?.id
    }

    private func beginSave() {
        saveName = defaultSaveName()
        showingSavePrompt = true
    }

    private func defaultSaveName() -> String {
        let stamp = Self.nameDateFormatter.string(from: Date())
        guard let id = anchorChapterId,
              editor.book.chapters.contains(where: { $0.id == id }) else { return stamp }
        return "\(PromptBuilder.chapterDisplayName(id, in: editor.book.chapters)) · \(stamp)"
    }

    private static let nameDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    /// Snapshots the live transcript onto the book. Chapter number and label
    /// are resolved *here*, once, and stored as literals — see `SavedChat`.
    private func saveChat() {
        let trimmed = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        var number: Int?
        var label = ""
        if let id = anchorChapterId, let idx = editor.book.chapters.firstIndex(where: { $0.id == id }) {
            let chapter = editor.book.chapters[idx]
            number = idx + 1
            label = chapter.name.isEmpty ? chapter.label : chapter.name
        }
        editor.book.savedChats.append(
            SavedChat(
                name: trimmed.isEmpty ? defaultSaveName() : trimmed,
                chapterNumber: number,
                chapterLabel: label,
                messages: messages
            )
        )
        editor.saveNow()
    }

    private func load(_ chat: SavedChat) {
        if persist { persistedHistory.replace(with: chat.messages) } else { localMessages = chat.messages }
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prompt = ""
        submit(text)
    }

    /// Re-sends the prompt whose turn failed. The failed user bubble was
    /// already rolled off the transcript, so this is an ordinary send of the
    /// same text — the history it builds on is exactly what it was the first
    /// time.
    private func retry() {
        guard let text = failedPrompt, !isLoading else { return }
        submit(text)
    }

    private func submit(_ text: String) {
        error = nil
        failedPrompt = nil
        let userMessage = ChatMessage(role: .user, content: text)
        append(userMessage)
        let scopeContext = includeBookText ? PromptBuilder.contentContextText(for: scope, book: editor.book) : ""
        // Broad context first, the chapter under discussion last: the thing
        // the question is actually about sits nearest the question.
        let digestContext = includeDigests
            ? PromptBuilder.digestContextText(
                digestEntries,
                upToChapter: digestCutoff.map { $0 + 1 },
                totalChapters: editor.book.chapters.count
            )
            : ""
        let context = [baseContext, digestContext, scopeContext].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let historyForCall = Array(messages.dropLast())

        let selectedCharacters = PromptBuilder.selectedCharacters(for: scope, book: editor.book)
        let usedBookText = includeBookText

        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let (result, usedModel) = try await env.llmService.chat(
                    text: context,
                    userPrompt: text,
                    history: historyForCall,
                    characters: selectedCharacters,
                    model: selectedModel,
                    settings: GenerationSettings(thinkingLevel: thinkingSetting.level, temperature: clampedTemperature)
                )
                var reply = result
                // Only the "off" case is recorded — that's the one the bubble
                // tags, and leaving the flag unset otherwise keeps ordinary
                // transcripts byte-identical to what they were before.
                if !usedBookText { reply.usedBookText = false }
                append(reply)
                modelUsed = usedModel == selectedModel ? nil : usedModel
            } catch {
                self.error = error.localizedDescription
                // Roll the user turn back off the transcript and hold its
                // text, so "Retry" re-sends the same prompt against the same
                // history instead of stacking a duplicate question above an
                // answer that never came.
                remove(userMessage)
                failedPrompt = text
            }
        }
    }
}

/// The "Load chat" picker: every snapshot saved against this book, newest
/// first, each showing the chapter it was about *as stamped at save time*.
struct SavedChatsListView: View {
    let savedChats: [SavedChat]
    let onLoad: (SavedChat) -> Void
    let onDelete: (SavedChat) -> Void

    @Environment(\.dismiss) private var dismiss

    private var sorted: [SavedChat] { savedChats.sorted { $0.savedAt > $1.savedAt } }

    var body: some View {
        List {
            ForEach(sorted) { chat in
                Button { onLoad(chat) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(chat.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.ink)
                        HStack(spacing: 6) {
                            if !chat.chapterDescription.isEmpty {
                                Text(chat.chapterDescription)
                                Text("·")
                            }
                            Text(chat.savedAt, style: .date)
                            Text("·")
                            Text("\(chat.messages.count) messages")
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                    }
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                for index in offsets { onDelete(sorted[index]) }
            }
            if savedChats.isEmpty {
                Text("No saved chats yet.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
        }
        .navigationTitle("Saved chats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Swipe-to-delete alone hides the fact that saved chats *can* be
            // deleted; the edit toggle says so out loud.
            ToolbarItem(placement: .topBarLeading) {
                EditButton().disabled(savedChats.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }
}
