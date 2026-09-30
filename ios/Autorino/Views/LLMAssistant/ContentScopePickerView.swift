import SwiftUI

/// Chapters/passages/characters context picker — the same idea as app.js's
/// `llmChapterSelected` scope list plus its separate `llmIncludeCharacters`
/// / `llmSelectedCharIds` character checklist (app.js:566-653, 731-734,
/// 2908-2917), collapsed into a small expandable section instead of a
/// permanently-visible checklist, since phone width doesn't have room for
/// that alongside the chat. The whole disclosure body scrolls internally
/// once it grows past a few rows, so a book with many chapters/characters
/// doesn't push the chat input off the bottom of the sheet.
///
/// A chapter carries two independent decisions — send its prose, send its
/// summary — so it gets two boxes on one row rather than appearing twice in
/// two lists. On a 25-chapter book a second list would have put the
/// summaries forty rows down a 220pt scroller, and the two choices about the
/// same chapter are easier to weigh side by side anyway.
struct ContentScopePickerView: View {
    let book: Book
    @Binding var selection: [ContentScopeItem]
    /// Chapters that actually have a stored summary, in manuscript order.
    var digestChapters: [(id: String, label: String)] = []
    /// Held as an *exclusion* set, not a selection: summaries are in by
    /// default and stay in as new ones are generated, so there is nothing to
    /// seed and nothing that silently drops out of scope later.
    @Binding var excludedDigests: Set<String>
    /// Zero-based index of the last chapter the summary range reaches, or
    /// `nil` for all of them. Rows past it are shown greyed rather than
    /// hidden, so the range is visible as a fact about the list instead of
    /// chapters mysteriously losing their box.
    var digestCutoff: Int?
    @State private var expanded = false

    private static let boxWidth: CGFloat = 20

    private var digestIds: Set<String> { Set(digestChapters.map(\.id)) }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        columnLegend
                        ForEach(Array(book.chapters.enumerated()), id: \.element.id) { index, chapter in
                            chapterRow(chapter, index: index)
                        }
                        ForEach(book.passages) { passage in
                            scopeRow(kind: .passage, id: passage.id,
                                     label: PromptBuilder.passageDisplayName(passage, in: book.chapters),
                                     leadingPad: true)
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

    /// Says what the two columns are without a word of explanation per row.
    /// The symbols are the ones these things wear elsewhere: the full-text
    /// page icon, and the summary icon from the chapter list's digest badge.
    private var columnLegend: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").frame(width: Self.boxWidth)
            Image(systemName: "list.bullet.rectangle")
                .frame(width: Self.boxWidth)
                .opacity(digestChapters.isEmpty ? 0.35 : 1)
            Text("Text · Summary")
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    /// `label` is `LocalizedStringKey`, not `String`: `Text` only looks a
    /// plain `String` up in the catalog when it's a literal, so building this
    /// as a `String` left the row in English inside an otherwise German UI.
    private var label: LocalizedStringKey {
        selection.isEmpty ? "Include chapters/passages/characters" : "Included: \(selection.count) selected"
    }

    private func chapterRow(_ chapter: Chapter, index: Int) -> some View {
        let textSelected = selection.contains { $0.kind == .chapter && $0.id == chapter.id }
        let hasDigest = digestIds.contains(chapter.id)
        let beyondCutoff = digestCutoff.map { index > $0 } ?? false
        let digestIncluded = hasDigest && !beyondCutoff && !excludedDigests.contains(chapter.id)
        return HStack(spacing: 8) {
            box(isOn: textSelected) { toggle(kind: .chapter, id: chapter.id) }
            if hasDigest {
                box(isOn: digestIncluded) {
                    if excludedDigests.contains(chapter.id) {
                        excludedDigests.remove(chapter.id)
                    } else {
                        excludedDigests.insert(chapter.id)
                    }
                }
                .disabled(beyondCutoff)
                .opacity(beyondCutoff ? 0.35 : 1)
            } else {
                // Held open so the labels stay in one column; a chapter with
                // no summary has nothing to switch off.
                Color.clear.frame(width: Self.boxWidth, height: 1)
            }
            Text(PromptBuilder.chapterDisplayName(chapter.id, in: book.chapters))
                .font(.footnote)
                .foregroundStyle(beyondCutoff && !textSelected ? Color.secondary : Color.primary)
            Spacer()
        }
    }

    private func box(isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                .frame(width: Self.boxWidth)
        }
        .buttonStyle(.plain)
    }

    private func toggle(kind: ContentScopeItem.Kind, id: String) {
        if selection.contains(where: { $0.kind == kind && $0.id == id }) {
            selection.removeAll { $0.kind == kind && $0.id == id }
        } else {
            selection.append(ContentScopeItem(kind: kind, id: id))
        }
    }

    private func scopeRow(kind: ContentScopeItem.Kind, id: String, label: String, leadingPad: Bool = false) -> some View {
        let isSelected = selection.contains { $0.kind == kind && $0.id == id }
        return HStack(spacing: 8) {
            box(isOn: isSelected) { toggle(kind: kind, id: id) }
            if leadingPad {
                Color.clear.frame(width: Self.boxWidth, height: 1)
            }
            Text(label).font(.footnote)
            Spacer()
        }
    }
}
