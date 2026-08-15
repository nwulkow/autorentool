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
    var title: String = "Assistant"

    var body: some View {
        NavigationStack {
            LLMAssistantContent(editor: editor, defaultScope: defaultScope, persist: persist, baseContext: baseContext, title: title)
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
    var title: String = "Assistant"

    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var persistedHistory: ChatHistoryStore
    @State private var localMessages: [ChatMessage] = []
    @State private var scope: [ContentScopeItem]
    @State private var prompt = ""
    @State private var isLoading = false
    @State private var error: String?

    init(editor: BookEditor, defaultScope: [ContentScopeItem] = [], persist: Bool = true, baseContext: String? = nil, title: String = "Assistant") {
        self.editor = editor
        self.defaultScope = defaultScope
        self.persist = persist
        self.baseContext = baseContext
        self.title = title
        _persistedHistory = StateObject(wrappedValue: ChatHistoryStore(bookTitle: editor.book.title))
        _scope = State(initialValue: defaultScope)
    }

    private var messages: [ChatMessage] { persist ? persistedHistory.messages : localMessages }

    var body: some View {
        VStack(spacing: 0) {
            ContentScopePickerView(book: editor.book, selection: $scope)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if messages.isEmpty {
                            Text("Ask about your characters, chapters, or plot. Turn on chapters/passages above to give the assistant more context.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding()
                        }
                        ForEach(messages) { message in
                            ChatBubbleView(message: message).id(message.id)
                        }
                        if isLoading {
                            HStack { ProgressView(); Text("Thinking…").font(.footnote).foregroundStyle(.secondary) }
                                .padding(.horizontal)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
            inputBar
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { clear() } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(messages.isEmpty)
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message…", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
        }
        .padding()
    }

    private func clear() {
        if persist { persistedHistory.clear() } else { localMessages = [] }
    }

    private func append(_ message: ChatMessage) {
        if persist { persistedHistory.append(message) } else { localMessages.append(message) }
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prompt = ""
        error = nil
        let userMessage = ChatMessage(role: .user, content: text)
        append(userMessage)
        let scopeContext = PromptBuilder.contentContextText(for: scope, book: editor.book)
        let context = [baseContext, scopeContext].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let historyForCall = Array(messages.dropLast())

        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let reply = try await env.llmService.chat(text: context, userPrompt: text, history: historyForCall, characters: editor.book.characters)
                append(reply)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
