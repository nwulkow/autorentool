import SwiftUI

/// Simple enough to implement in full this phase rather than defer
/// (unlike Canvas/Locations/Event orders/Notes, which need real
/// drag/drawing/timeline surfaces). Mirrors app.js's questions tab
/// (app.js:1304-1311).
struct QuestionsListView: View {
    @ObservedObject var editor: BookEditor
    @State private var newQuestionText = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("New question…", text: $newQuestionText)
                    Button("Add") { addQuestion() }
                        .disabled(newQuestionText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if editor.book.questions.isEmpty {
                Text("No questions yet.").foregroundStyle(.secondary)
            } else {
                ForEach($editor.book.questions) { $question in
                    QuestionRow(question: $question)
                }
                .onDelete { indexSet in
                    editor.book.questions.remove(atOffsets: indexSet)
                }
            }
        }
        .navigationTitle("Questions")
    }

    private func addQuestion() {
        let text = newQuestionText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        editor.book.questions.append(Question(text: text))
        newQuestionText = ""
    }
}

private struct QuestionRow: View {
    @Binding var question: Question

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    question.answered.toggle()
                } label: {
                    Image(systemName: question.answered ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(question.answered ? .green : .secondary)
                }
                .buttonStyle(.plain)
                Text(question.text)
                    .strikethrough(question.answered)
            }
            TextField("Answer…", text: $question.answer, axis: .vertical)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
