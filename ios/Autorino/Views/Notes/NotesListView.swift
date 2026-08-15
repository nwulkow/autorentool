import SwiftUI

/// Mirrors app.js's Notes tab topics sidebar (`.topics-sidebar`,
/// app.js:2580-2595, and `addTopic`/`removeTopic`, app.js:1401-1408): the
/// book's topics, each opening into `TopicDetailView` (the post-it grid +
/// links sidebar, collapsed into a pushed detail screen at phone width
/// instead of app.js's three-pane `.notes-layout`).
///
/// Embedded in `NotesTabView`, so it sets no `navigationTitle` of its own.
struct NotesListView: View {
    @ObservedObject var editor: BookEditor
    @State private var newTopicName = ""

    var body: some View {
        Group {
            if editor.book.topics.isEmpty {
                EmptyStateView(
                    systemImage: "note.text",
                    title: String(localized: "No topics yet."),
                    message: String(localized: "Create a topic to start adding post-it notes and links.")
                )
            } else {
                List {
                    ForEach(editor.book.topics) { topic in
                        NavigationLink {
                            TopicDetailView(editor: editor, topicId: topic.id)
                        } label: {
                            TopicRow(topic: topic)
                        }
                        .bookCardRow()
                    }
                    .onDelete { indexSet in
                        editor.book.topics.remove(atOffsets: indexSet)
                    }
                }
                .listStyle(.plain)
                .paperBackground()
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                TextField("New topic…", text: $newTopicName)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                            .stroke(Theme.line, lineWidth: 1)
                    )
                Button {
                    addTopic()
                } label: {
                    Text("Add")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
                }
                .buttonStyle(.plain)
                .opacity(newTopicName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                .disabled(newTopicName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.chrome)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line), alignment: .top)
        }
    }

    private func addTopic() {
        let name = newTopicName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        editor.book.topics.append(Topic(name: name))
        newTopicName = ""
    }
}

private struct TopicRow: View {
    let topic: Topic

    var body: some View {
        HStack {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(Theme.accent)
            Text(topic.name)
                .font(Theme.rowTitle)
                .foregroundStyle(Theme.ink)
            Spacer()
            Text("\(topic.notes.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Theme.accentSoft, in: Capsule())
        }
        .bookCard(padding: 14)
    }
}
