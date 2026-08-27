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
    @State private var showingSavePrompt = false
    @State private var saveName = ""
    @State private var showingSavedChats = false

    init(editor: BookEditor, defaultScope: [ContentScopeItem] = [], persist: Bool = true, baseContext: String? = nil, title: String = String(localized: "Assistant"), contextChapterId: String? = nil) {
        self.editor = editor
        self.defaultScope = defaultScope
        self.persist = persist
        self.baseContext = baseContext
        self.title = title
        self.contextChapterId = contextChapterId
        _persistedHistory = StateObject(wrappedValue: ChatHistoryStore(bookTitle: editor.book.title))
        _scope = State(initialValue: defaultScope)
    }

    private var messages: [ChatMessage] { persist ? persistedHistory.messages : localMessages }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                modelPickerRow
                ContentScopePickerView(book: editor.book, selection: $scope)
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
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
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

    /// Deliberately a plain checkbox row rather than a `Toggle` switch: it
    /// belongs to the same "what goes in the prompt" group as the scope
    /// picker's checkmarks directly above it, and reads as one list.
    private var includeBookTextRow: some View {
        Button {
            includeBookText.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: includeBookText ? "checkmark.square.fill" : "square")
                    .foregroundStyle(includeBookText ? Color.accentColor : .secondary)
                Text("Include book text")
                    .font(.footnote)
                    .foregroundStyle(Theme.ink)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.bottom, 8)
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
        error = nil
        let userMessage = ChatMessage(role: .user, content: text)
        append(userMessage)
        let scopeContext = includeBookText ? PromptBuilder.contentContextText(for: scope, book: editor.book) : ""
        let context = [baseContext, scopeContext].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let historyForCall = Array(messages.dropLast())

        let selectedCharacters = PromptBuilder.selectedCharacters(for: scope, book: editor.book)
        let usedBookText = includeBookText

        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let (result, usedModel) = try await env.llmService.chat(text: context, userPrompt: text, history: historyForCall, characters: selectedCharacters, model: selectedModel)
                var reply = result
                // Only the "off" case is recorded — that's the one the bubble
                // tags, and leaving the flag unset otherwise keeps ordinary
                // transcripts byte-identical to what they were before.
                if !usedBookText { reply.usedBookText = false }
                append(reply)
                modelUsed = usedModel == selectedModel ? nil : usedModel
            } catch {
                self.error = error.localizedDescription
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
