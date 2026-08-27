import SwiftUI

/// Entry point for the LLM assistant from any tab. Kept as its own view
/// so every screen that gets a chat surface (Editor, Event orders, …)
/// opens it the same way, and toggles a `Bool` binding rather than owning
/// presentation itself — see `LLMAssistantHost` for what that binding
/// drives (a sheet on compact width, a permanent trailing column on
/// regular width, matching app.js's own docked side panel there).
struct LLMAssistantButton: View {
    @Binding var isPresented: Bool

    init(isPresented: Binding<Bool>) {
        _isPresented = isPresented
    }

    /// Back-compat convenience for call sites still passing a plain
    /// closure instead of the presentation binding.
    init(action: @escaping () -> Void) {
        _isPresented = .init(get: { false }, set: { if $0 { action() } })
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("Assistant", systemImage: "sparkles")
        }
    }
}

/// Wraps a content view with an LLM assistant surface that adapts to size
/// class: a `.sheet` on compact width (iPhone), a `NavigationSplitView`
/// trailing column on regular width (iPad, Mac Catalyst) so the assistant
/// can stay open alongside the tab it's discussing — app.js docks its LLM
/// panel permanently next to the editor on desktop; this is the same idea,
/// deferred until now because it needed size-class branching this phase
/// finally does. See `docs/migration-architecture.md` §6.5.
struct LLMAssistantHost<Content: View>: View {
    @ObservedObject var editor: BookEditor
    @Binding var isPresented: Bool
    var defaultScope: [ContentScopeItem] = []
    var persist = true
    var baseContext: String?
    var title: String = String(localized: "Assistant")
    var contextChapterId: String?
    @ViewBuilder var content: () -> Content

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                content()
            } detail: {
                if isPresented {
                    NavigationStack {
                        LLMAssistantContent(editor: editor, defaultScope: defaultScope, persist: persist, baseContext: baseContext, title: title, contextChapterId: contextChapterId)
                    }
                } else {
                    EmptyStateView(
                        systemImage: "sparkles",
                        title: String(localized: "Assistant"),
                        message: String(localized: "Tap Assistant to start a conversation."),
                        actionTitle: nil, action: nil
                    )
                }
            }
        } else {
            content()
                .sheet(isPresented: $isPresented) {
                    LLMAssistantSheet(editor: editor, defaultScope: defaultScope, persist: persist, baseContext: baseContext, title: title, contextChapterId: contextChapterId)
                }
        }
    }
}
