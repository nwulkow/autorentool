import SwiftUI

/// Comments anchored by plain-text offset+length (`rangeIndex`/
/// `rangeLength`) into the chapter's text — same concept as Quill's range
/// anchoring (app.js chapter `comments`), just without the framework.
struct CommentsListView: View {
    @Binding var comments: [Comment]

    var body: some View {
        NavigationStack {
            List {
                if comments.isEmpty {
                    Text("No comments yet. Select text in the editor and tap “Comment” to add one.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(comments) { comment in
                        VStack(alignment: .leading, spacing: 4) {
                            if !comment.selection.isEmpty {
                                Text("“\(comment.selection)”")
                                    .font(.caption)
                                    .italic()
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Text(comment.text)
                        }
                    }
                    .onDelete { indexSet in comments.remove(atOffsets: indexSet) }
                }
            }
            .navigationTitle("Comments")
        }
    }
}

struct AddCommentSheet: View {
    @Binding var comments: [Comment]
    let selection: String
    let rangeIndex: Int
    let rangeLength: Int
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                if !selection.isEmpty {
                    Section("Selected text") {
                        Text(selection).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                    }
                }
                Section("Comment") {
                    TextField("Comment…", text: $text, axis: .vertical)
                }
            }
            .navigationTitle("Add Comment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        comments.append(Comment(text: text, selection: selection, rangeIndex: rangeIndex, rangeLength: rangeLength))
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
