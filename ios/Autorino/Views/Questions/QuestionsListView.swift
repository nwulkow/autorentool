import SwiftUI

/// Mirrors app.js's questions tab (app.js:1304-1311). Embedded in
/// `NotesTabView` alongside topics, so it sets no `navigationTitle` of its
/// own.
struct QuestionsListView: View {
    @ObservedObject var editor: BookEditor
    @State private var newQuestionText = ""

    var body: some View {
        Group {
            if editor.book.questions.isEmpty {
                EmptyStateView(
                    systemImage: "questionmark.circle",
                    title: String(localized: "No questions yet."),
                    message: String(localized: "Track what you still need to figure out.")
                )
            } else {
                List {
                    ForEach($editor.book.questions) { $question in
                        QuestionRow(question: $question)
                            .bookCardRow()
                    }
                    .onDelete { indexSet in
                        editor.book.questions.remove(atOffsets: indexSet)
                    }
                }
                .listStyle(.plain)
                .paperBackground()
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                TextField("New question…", text: $newQuestionText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                            .stroke(Theme.line, lineWidth: 1)
                    )
                Button {
                    addQuestion()
                } label: {
                    Text("Add")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
                }
                .buttonStyle(.plain)
                .opacity(newQuestionText.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                .disabled(newQuestionText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.chrome)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line), alignment: .top)
        }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    question.answered.toggle()
                } label: {
                    Image(systemName: question.answered ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(question.answered ? Color(uiColor: .systemGreen) : Theme.muted)
                }
                .buttonStyle(.plain)

                Text(question.text)
                    .font(Theme.serif(16, relativeTo: .body))
                    .foregroundStyle(question.answered ? Theme.muted : Theme.ink)
                    .strikethrough(question.answered)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            TextField("Answer…", text: $question.answer, axis: .vertical)
                .font(.footnote)
                .foregroundStyle(Theme.muted)
                .padding(.leading, 30)
        }
        .bookCard(padding: 14)
    }
}
