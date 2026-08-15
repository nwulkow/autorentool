import SwiftUI

/// The redesigned LLM chat surface for iPhone. app.js docks this in a
/// permanent side panel next to the editor (fine on desktop, unusable on a
/// ~390pt-wide phone). Here it's a bottom-sheet drawer that starts at
/// `.medium` — the editor stays visible above it — and can be dragged to
/// `.large` for a focused conversation. See
/// `docs/migration-architecture.md` §6 for the full rationale.
struct LLMAssistantSheet: View {
    @ObservedObject var editor: BookEditor
    var defaultScope: [ContentScopeItem] = []

    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var history: ChatHistoryStore
    @State private var scope: [ContentScopeItem]
    @State private var prompt = ""
    @State private var isLoading = false
    @State private var error: String?

    init(editor: BookEditor, defaultScope: [ContentScopeItem] = []) {
        self.editor = editor
        self.defaultScope = defaultScope
        _history = StateObject(wrappedValue: ChatHistoryStore(bookTitle: editor.book.title))
        _scope = State(initialValue: defaultScope)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ContentScopePickerView(book: editor.book, selection: $scope)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if history.messages.isEmpty {
                                Text("Ask about your characters, chapters, or plot. Turn on chapters/passages above to give the assistant more context.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding()
                            }
                            ForEach(history.messages) { message in
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
                    .onChange(of: history.messages.count) { _, _ in
                        if let last = history.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
                }
                inputBar
            }
            .navigationTitle("Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { history.clear() } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .disabled(history.messages.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prompt = ""
        error = nil
        let userMessage = ChatMessage(role: .user, content: text)
        history.append(userMessage)
        let context = PromptBuilder.contentContextText(for: scope, book: editor.book)
        let historyForCall = Array(history.messages.dropLast())

        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let reply = try await env.llmService.chat(text: context, userPrompt: text, history: historyForCall, characters: editor.book.characters)
                history.append(reply)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
