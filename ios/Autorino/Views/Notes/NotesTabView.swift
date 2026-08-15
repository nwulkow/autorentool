import SwiftUI

/// Notes and Questions are both "things to remember / resolve later", and
/// neither fills a tab on its own, so they share one. Questions was a
/// top-level tab in the first layout; folding it in here frees the fifth
/// slot for "More".
struct NotesTabView: View {
    @ObservedObject var editor: BookEditor

    enum Mode: Hashable { case notes, questions }
    @State private var mode: Mode = .notes

    var body: some View {
        VStack(spacing: 0) {
            BookSegmentedControl(
                selection: $mode,
                options: [
                    (value: .notes, label: String(localized: "Topics"), systemImage: "note.text"),
                    (value: .questions, label: String(localized: "Questions"), systemImage: "questionmark.circle"),
                ]
            )

            switch mode {
            case .notes: NotesListView(editor: editor)
            case .questions: QuestionsListView(editor: editor)
            }
        }
        .background(Theme.paper)
        .navigationTitle("Notes")
    }
}
