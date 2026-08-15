import SwiftUI

/// Replaces app.js's per-book tab bar. The bar is five slots deep, ordered
/// by how often writing actually touches them: **Text** first (and the
/// default when a book opens — you came here to write), then Characters
/// (which now also holds the relationship map), Event Orders, Notes (which
/// now also holds Questions), and More (Locations, Settings).
///
/// This is deliberately not app.js's flat seven-tab row: seven doesn't fit
/// a phone tab bar, and iOS collapses anything past five into a system
/// "More" list. Folding Canvas into Characters and Questions into Notes
/// keeps every destination one tap away and leaves the fifth slot for a
/// "More" tab we control (`MoreTabView`) instead of the system's.
struct BookTabContainer: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject var editor: BookEditor
    @State private var showingRename = false
    @State private var renameText = ""

    var body: some View {
        TabView {
            ChapterListView(editor: editor)
                .tabItem { Label("Text", systemImage: "book.closed") }

            CharactersTabView(editor: editor)
                .tabItem { Label("Characters", systemImage: "person.2") }

            EventOrdersListView(editor: editor)
                .tabItem { Label("Event Orders", systemImage: "clock.arrow.circlepath") }

            NotesTabView(editor: editor)
                .tabItem { Label("Notes", systemImage: "note.text") }

            MoreTabView(editor: editor)
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
        }
        .tint(Theme.accent)
        .navigationTitle(editor.book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    renameText = editor.book.title
                    showingRename = true
                } label: {
                    Text(editor.book.title)
                        .font(Theme.serif(17, relativeTo: .headline))
                        .foregroundStyle(Theme.ink)
                }
            }
        }
        .alert("Rename Book", isPresented: $showingRename) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed != editor.book.title else { return }
                editor.book = env.bookStore.rename(editor.book, to: trimmed)
            }
        }
    }
}
