import SwiftUI

/// Mirrors app.js's Characters tab (app.js:947-998): add/remove, tags
/// (shared, book-level tag pool with per-character suggestions), and the
/// deletion cascade into relations/canvas nodes/event columns.
///
/// Embedded in `CharactersTabView`, so it sets no `navigationTitle` of its
/// own and keeps its "add" control in the body rather than `.toolbar` —
/// tab content toolbars don't merge into the shared nav bar (see
/// `ios/README-iOS.md`).
struct CharactersListView: View {
    @ObservedObject var editor: BookEditor
    @State private var showingAdd = false

    var body: some View {
        Group {
            if editor.book.characters.isEmpty {
                EmptyStateView(
                    systemImage: "person.2",
                    title: String(localized: "No characters yet."),
                    message: String(localized: "Add the people who populate your story."),
                    actionTitle: String(localized: "+ Add Character")
                ) { showingAdd = true }
            } else {
                List {
                    ForEach(editor.book.characters) { character in
                        NavigationLink {
                            CharacterDetailView(editor: editor, characterId: character.id)
                        } label: {
                            CharacterRow(character: character, color: CharacterPalette.color(for: character.id, in: editor.book.characters))
                        }
                        .bookCardRow()
                    }
                    .onDelete { indexSet in
                        for index in indexSet { removeCharacter(editor.book.characters[index].id) }
                    }
                }
                .listStyle(.plain)
                .paperBackground()
                .safeAreaInset(edge: .bottom) {
                    AddBarButton(title: String(localized: "Add Character")) { showingAdd = true }
                }
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

/// The card treatment from `.char-card` (styles.css:182-189) — a white
/// panel with the character's palette color as a left spine, which is how
/// the web app ties a character to their timeline column and canvas node.
private struct CharacterRow: View {
    let character: Character
    let color: Color

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(color)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 6) {
                Text(character.name)
                    .font(Theme.rowTitle)
                    .foregroundStyle(Theme.ink)
                if !character.description.isEmpty {
                    Text(character.description)
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
                if !character.tags.isEmpty {
                    TagFlowLayout {
                        ForEach(character.tags, id: \.self) { TagChipView(text: $0) }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .stroke(Theme.line, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 1)
    }
}

/// The primary-action bar used at the bottom of tab content, standing in
/// for the `.toolbar` add button that a tab child can't put in the nav bar.
/// Mirrors `button.primary` (styles.css:42-44).
struct AddBarButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.chrome)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line), alignment: .top)
    }
}
