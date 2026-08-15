import SwiftUI

/// Mirrors app.js's Characters tab (app.js:947-998): add/remove, tags
/// (shared, book-level tag pool with per-character suggestions), and the
/// deletion cascade into relations/canvas nodes/event columns.
struct CharactersListView: View {
    @ObservedObject var editor: BookEditor
    @State private var showingAdd = false

    var body: some View {
        Group {
            if editor.book.characters.isEmpty {
                EmptyStateView(
                    systemImage: "person.2",
                    title: "No characters yet.",
                    message: "Add the people who populate your story.",
                    actionTitle: "+ Add Character"
                ) { showingAdd = true }
            } else {
                List {
                    ForEach(editor.book.characters) { character in
                        NavigationLink {
                            CharacterDetailView(editor: editor, characterId: character.id)
                        } label: {
                            CharacterRow(character: character)
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet { removeCharacter(editor.book.characters[index].id) }
                    }
                }
            }
        }
        .navigationTitle("Characters")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: { Label("Add Character", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showingAdd) {
            CharacterEditSheet(editor: editor)
        }
    }

    /// Mirrors `removeCharacter` (app.js:955-962) — deleting a character
    /// also drops its relations, canvas node, and any event-order columns.
    private func removeCharacter(_ id: String) {
        editor.book.characters.removeAll { $0.id == id }
        editor.book.characterRelations.removeAll { $0.character1Id == id || $0.character2Id == id }
        editor.book.canvasNodes.removeAll { $0.characterId == id }
        for index in editor.book.eventOrders.indices {
            editor.book.eventOrders[index].characterColumns.removeAll { $0.characterId == id }
        }
    }
}

private struct CharacterRow: View {
    let character: Character

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(character.name).font(.headline)
            if !character.description.isEmpty {
                Text(character.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !character.tags.isEmpty {
                TagFlowLayout {
                    ForEach(character.tags, id: \.self) { TagChipView(text: $0) }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
