import SwiftUI

/// Mirrors app.js's Notes tab topics sidebar (`.topics-sidebar`,
/// app.js:2580-2595, and `addTopic`/`removeTopic`, app.js:1401-1408): the
/// book's topics, each opening into `TopicDetailView` (the post-it grid +
/// links sidebar, collapsed into a pushed detail screen at phone width
/// instead of app.js's three-pane `.notes-layout`).
struct NotesListView: View {
    @ObservedObject var editor: BookEditor
    @State private var newTopicName = ""

    var body: some View {
        Group {
            if editor.book.topics.isEmpty {
                EmptyStateView(
                    systemImage: "note.text",
                    title: "No topics yet.",
                    message: "Create a topic to start adding post-it notes and links."
                )
            } else {
                List {
                    ForEach(editor.book.topics) { topic in
                        NavigationLink {
                            TopicDetailView(editor: editor, topicId: topic.id)
                        } label: {
                            TopicRow(topic: topic)
                        }
                    }
                    .onDelete { indexSet in
                        editor.book.topics.remove(atOffsets: indexSet)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                TextField("New topic…", text: $newTopicName)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { addTopic() }
                    .disabled(newTopicName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
            .background(.bar)
        }
        .navigationTitle("Notes")
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
            Text(topic.name).font(.headline)
            Spacer()
            Text("\(topic.notes.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: Capsule())
        }
        .padding(.vertical, 4)
    }
}
