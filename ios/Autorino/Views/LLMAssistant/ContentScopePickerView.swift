import SwiftUI

/// Chapters/passages context picker — the same idea as app.js's
/// `llmChapterSelected` (app.js:566-653), collapsed into a small
/// expandable section instead of a permanently-visible checklist, since
/// phone width doesn't have room for that alongside the chat.
struct ContentScopePickerView: View {
    let book: Book
    @Binding var selection: [ContentScopeItem]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
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
            .padding(.top, 4)
        } label: {
            Text(label)
                .font(.subheadline)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var label: String {
        selection.isEmpty ? "Include chapters/passages" : "Included: \(selection.count) selected"
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
