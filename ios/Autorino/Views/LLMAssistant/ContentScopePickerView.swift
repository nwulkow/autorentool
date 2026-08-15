import SwiftUI

/// Chapters/passages/characters context picker — the same idea as app.js's
/// `llmChapterSelected` scope list plus its separate `llmIncludeCharacters`
/// / `llmSelectedCharIds` character checklist (app.js:566-653, 731-734,
/// 2908-2917), collapsed into a small expandable section instead of a
/// permanently-visible checklist, since phone width doesn't have room for
/// that alongside the chat. The whole disclosure body scrolls internally
/// once it grows past a few rows, so a book with many chapters/characters
/// doesn't push the chat input off the bottom of the sheet.
struct ContentScopePickerView: View {
    let book: Book
    @Binding var selection: [ContentScopeItem]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(book.chapters.enumerated()), id: \.element.id) { idx, chapter in
                            scopeRow(kind: .chapter, id: chapter.id, label: PromptBuilder.chapterDisplayName(chapter.id, in: book.chapters))
                        }
                        ForEach(book.passages) { passage in
                            scopeRow(kind: .passage, id: passage.id, label: PromptBuilder.passageDisplayName(passage, in: book.chapters))
                        }
                        if book.chapters.isEmpty && book.passages.isEmpty {
                            Text("No chapters yet.").font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Characters")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(book.characters) { character in
                            scopeRow(kind: .character, id: character.id, label: character.name)
                        }
                        if book.characters.isEmpty {
                            Text("No characters yet.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxHeight: 220)
        } label: {
            Text(label)
                .font(.subheadline)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    /// `LocalizedStringKey`, not `String`: `Text` only looks a plain `String`
    /// up in the catalog when it's a literal, so building this as a `String`
    /// left the row in English inside an otherwise German UI.
    private var label: LocalizedStringKey {
        selection.isEmpty ? "Include chapters/passages/characters" : "Included: \(selection.count) selected"
    }

    private func scopeRow(kind: ContentScopeItem.Kind, id: String, label: String) -> some View {
        let isSelected = selection.contains { $0.kind == kind && $0.id == id }
        return Button {
            if isSelected {
                selection.removeAll { $0.kind == kind && $0.id == id }
            } else {
                selection.append(ContentScopeItem(kind: kind, id: id))
            }
        } label: {
            HStack {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(label).font(.footnote)
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }
}
