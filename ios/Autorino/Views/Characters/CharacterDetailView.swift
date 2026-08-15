import SwiftUI

/// Mirrors the tag-adding/suggestion flow (`addTagToChar`/`pickTag`/
/// `filteredTagsFor`, app.js:963-996): tags are a book-level shared pool,
/// with per-character suggestions of tags not yet applied to that character.
struct CharacterDetailView: View {
    @ObservedObject var editor: BookEditor
    let characterId: String
    @State private var tagInput = ""

    private var index: Int? { editor.book.characters.firstIndex { $0.id == characterId } }

    var body: some View {
        Group {
            if let index {
                Form {
                    Section("Name") {
                        TextField("Name", text: $editor.book.characters[index].name)
                    }
                    Section("Description") {
                        TextField("Description", text: $editor.book.characters[index].description, axis: .vertical)
                            .lineLimit(4...10)
                    }
                    Section("Tags") {
                        if !editor.book.characters[index].tags.isEmpty {
                            TagFlowLayout {
                                ForEach(editor.book.characters[index].tags, id: \.self) { tag in
                                    TagChipView(text: tag) {
                                        editor.book.characters[index].tags.removeAll { $0 == tag }
                                    }
                                }
                            }
                        }
                        HStack {
                            TextField("Add tag…", text: $tagInput)
                                .textInputAutocapitalization(.never)
                            Button("Add") { addTag(tagInput) }
                                .disabled(tagInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        let suggestions = filteredSuggestions(index: index)
                        if !suggestions.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(suggestions, id: \.self) { tag in
                                        Button {
                                            addTag(tag)
                                        } label: {
                                            TagChipView(text: tag)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle(editor.book.characters[index].name.isEmpty ? "Character" : editor.book.characters[index].name)
                .navigationBarTitleDisplayMode(.inline)
            } else {
                EmptyStateView(systemImage: "person.crop.circle.badge.xmark", title: "Character removed", message: "This character no longer exists.")
            }
        }
    }

    private func filteredSuggestions(index: Int) -> [String] {
        let existing = Set(editor.book.characters[index].tags)
        let filter = tagInput.trimmingCharacters(in: .whitespaces).lowercased()
        return editor.book.tags.filter { !existing.contains($0) && (filter.isEmpty || $0.lowercased().contains(filter)) }
    }

    private func addTag(_ raw: String) {
        guard let index else { return }
        let tag = raw.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty else { return }
        if !editor.book.characters[index].tags.contains(tag) {
            editor.book.characters[index].tags.append(tag)
        }
        if !editor.book.tags.contains(tag) {
            editor.book.tags.append(tag)
        }
        tagInput = ""
    }
}
