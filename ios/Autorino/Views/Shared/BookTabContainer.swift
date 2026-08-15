import SwiftUI

/// Replaces app.js's per-book tab bar (Characters / Canvas / Locations /
/// Event orders / Questions / Notes / Editor). Notes is the last remaining
/// `PlaceholderTabView` — its data model already exists (see `Models/`), the
/// view lands in a later phase. Event orders landed in
/// `EventOrdersListView`/`TimelineView`, minus the LLM assistant side panel
/// (deferred — it duplicates `LLMAssistantSheet`'s machinery). Canvas
/// landed in `CanvasView`, Locations in `LocationsListView`.
struct BookTabContainer: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject var editor: BookEditor
    @State private var showingRename = false
    @State private var renameText = ""

    var body: some View {
        TabView {
            CharactersListView(editor: editor)
                .tabItem { Label("Characters", systemImage: "person.2") }

            CanvasView(editor: editor)
                .tabItem { Label("Canvas", systemImage: "point.3.connected.trianglepath.dotted") }

            LocationsListView(editor: editor)
                .tabItem { Label("Locations", systemImage: "mappin.and.ellipse") }

            EventOrdersListView(editor: editor)
                .tabItem { Label("Timeline", systemImage: "clock.arrow.circlepath") }

            QuestionsListView(editor: editor)
                .tabItem { Label("Questions", systemImage: "questionmark.circle") }

            PlaceholderTabView(title: "Notes", systemImage: "note.text",
                                note: "The post-it notes board is coming in the next update.")
                .tabItem { Label("Notes", systemImage: "note.text") }

            ChapterListView(editor: editor)
                .tabItem { Label("Editor", systemImage: "doc.text") }
        }
        .navigationTitle(editor.book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    renameText = editor.book.title
                    showingRename = true
                } label: {
                    Text(editor.book.title).font(.headline)
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
