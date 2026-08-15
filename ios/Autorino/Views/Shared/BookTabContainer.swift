import SwiftUI

/// Replaces app.js's per-book tab bar. The bar is five slots deep, ordered
/// by how often writing actually touches them: **Text** first (and the
/// default when a book opens — you came here to write), then Characters
/// (which now also holds the relationship map), Event Orders, Notes (which
/// now also holds Questions), and More (Locations, for now).
///
/// This is deliberately not app.js's flat seven-tab row: seven doesn't fit
/// a phone tab bar, and iOS collapses anything past five into a system
/// "More" list. Folding Canvas into Characters and Questions into Notes
/// keeps every destination one tap away and leaves the fifth slot for a
/// "More" tab we control (`MoreTabView`) instead of the system's.
///
/// Settings is reachable via the gear icon in the toolbar below, mirroring
/// `RootView`'s top-right gear on the book list — both present `SettingsView`
/// as a sheet, since it owns its own `NavigationStack` and a `dismiss()`-driven
/// Done button that only behave correctly when presented modally.
struct BookTabContainer: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject var editor: BookEditor
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var showingSettings = false
    /// Told about a successful rename so the caller (`BookListView`) can
    /// rewrite its navigation path — see the note on `BookListView.path`.
    /// Optional/no-op default so other callers (previews, tests) don't need
    /// to supply one.
    var onRename: (String) -> Void = { _ in }

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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                SyncStatusButton()
            }
        }
        .alert("Rename Book", isPresented: $showingRename) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed != editor.book.title else { return }
                editor.book = env.bookStore.rename(editor.book, to: trimmed)
                onRename(editor.book.title)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
}
