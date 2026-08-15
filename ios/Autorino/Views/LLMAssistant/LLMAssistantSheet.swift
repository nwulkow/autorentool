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
    var title: String = String(localized: "Assistant")

    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var persistedHistory: ChatHistoryStore
    @State private var localMessages: [ChatMessage] = []
    @State private var scope: [ContentScopeItem]
    @State private var prompt = ""
    @State private var isLoading = false
    @State private var error: String?

    init(editor: BookEditor, defaultScope: [ContentScopeItem] = [], persist: Bool = true, baseContext: String? = nil, title: String = String(localized: "Assistant")) {
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
                Button(role: .destructive) { clear() } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(messages.isEmpty)
            }
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
        String(localized: "Summarize what happens here."),
        String(localized: "What's inconsistent or unclear?"),
        String(localized: "Suggest three ways this could continue."),
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

        let selectedCharacters = PromptBuilder.selectedCharacters(for: scope, book: editor.book)

        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let reply = try await env.llmService.chat(text: context, userPrompt: text, history: historyForCall, characters: selectedCharacters)
                append(reply)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
