import SwiftUI

/// Read-only concatenation of every chapter's title + body — mirrors
/// today's full-text mode (`fullTextQuill` in app.js).
struct FullTextView: View {
    @ObservedObject var editor: BookEditor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(editor.book.chapters) { chapter in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(chapter.name.isEmpty ? chapter.label : "\(chapter.label) – \(chapter.name)")
                            .font(.title3).bold()
                        Text(PromptBuilder.chapterPlainText(chapter))
                            .font(.body)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Full text")
        .navigationBarTitleDisplayMode(.inline)
    }
}
