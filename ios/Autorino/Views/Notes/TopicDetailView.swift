import SwiftUI

/// Mirrors app.js's `.notes-main` + `.urls-sidebar` for the selected topic
/// (app.js:2598-2632): a post-it grid (`addNote`/`removeNote`,
/// app.js:1410-1416) plus a list of URL links (`addUrl`/`removeUrl`,
/// app.js:1418-1424). Stacked vertically instead of side-by-side sidebars,
/// same phone-width adaptation as the rest of the app.
struct TopicDetailView: View {
    @ObservedObject var editor: BookEditor
    let topicId: String

    @State private var newUrl = ""

    private var topicIndex: Int? {
        editor.book.topics.firstIndex { $0.id == topicId }
    }

    var body: some View {
        Group {
            if let topicIndex {
                List {
                    Section("Post-it Notes") {
                        ForEach($editor.book.topics[topicIndex].notes) { $note in
                            PostItRow(note: $note) {
                                editor.book.topics[topicIndex].notes.removeAll { $0.id == note.id }
                            }
                        }
                        Button {
                            editor.book.topics[topicIndex].notes.append(Note())
                        } label: {
                            Label("Add Note", systemImage: "plus")
                        }
                    }

                    Section("Links") {
                        ForEach(Array(editor.book.topics[topicIndex].urlLinks.enumerated()), id: \.offset) { i, url in
                            HStack {
                                if let link = URL(string: url) {
                                    Link(url, destination: link)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                } else {
                                    Text(url).lineLimit(1)
                                }
                            }
                        }
                        .onDelete { indexSet in
                            editor.book.topics[topicIndex].urlLinks.remove(atOffsets: indexSet)
                        }
                        HStack {
                            TextField("https://…", text: $newUrl)
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .onSubmit { addUrl() }
                            Button("Add") { addUrl() }
                                .disabled(newUrl.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                .navigationTitle(editor.book.topics[topicIndex].name)
                .navigationBarTitleDisplayMode(.inline)
            } else {
                EmptyStateView(
                    systemImage: "note.text",
                    title: String(localized: "Topic removed"),
                    message: String(localized: "This topic no longer exists.")
                )
            }
        }
    }

    private func addUrl() {
        guard let topicIndex else { return }
        let url = newUrl.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        editor.book.topics[topicIndex].urlLinks.append(url)
        newUrl = ""
    }
}

/// A single post-it note: text, a color picker matching app.js's
/// `POST_IT_COLORS` (app.js:24-29), and delete.
private struct PostItRow: View {
    @Binding var note: Note
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Write a note…", text: $note.text, axis: .vertical)
                .lineLimit(3...8)
            HStack {
                Menu {
                    ForEach(NotePostItColor.all, id: \.value) { color in
                        Button {
                            note.color = color.value
                        } label: {
                            Label(color.label, systemImage: note.color == color.value ? "checkmark" : "")
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(CSSColor.color(note.color, fallback: .yellow))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(.secondary.opacity(0.3), lineWidth: 1))
                        Text(NotePostItColor.label(for: note.color))
                            .font(.caption)
                    }
                }
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(CSSColor.color(note.color, fallback: .yellow), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Port of app.js's `POST_IT_COLORS` (app.js:24-29).
enum NotePostItColor {
    static let all: [(value: String, label: String)] = [
        ("#fff9c4", "Yellow"), ("#f8bbd0", "Pink"),
        ("#bbdefb", "Blue"), ("#c8e6c9", "Green"),
        ("#ffe0b2", "Orange"), ("#e1bee7", "Purple"),
        ("#b2dfdb", "Teal"), ("#ffccbc", "Peach"),
    ]

    static func label(for value: String) -> String {
        all.first { $0.value == value }?.label ?? value
    }
}
