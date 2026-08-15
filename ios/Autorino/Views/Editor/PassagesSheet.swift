import SwiftUI

/// Mirrors `verifyPassage`/`addPassage` (app.js:611-633): a passage is
/// defined by start/end anchor text that must both be found (in order) in
/// the chapter's plain text — verified before it can be saved.
struct PassagesSheet: View {
    @ObservedObject var editor: BookEditor
    let chapterId: String
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var startText = ""
    @State private var endText = ""
    @State private var error = ""
    @State private var verified = false

    private var chapterPassages: [Passage] {
        editor.book.passages.filter { $0.chapterId == chapterId }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Existing passages") {
                    if chapterPassages.isEmpty {
                        Text("None yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(chapterPassages) { passage in
                            VStack(alignment: .leading) {
                                Text(passage.name).font(.subheadline)
                                Text("“\(passage.startText)” … “\(passage.endText)”")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .onDelete { indexSet in
                            let toRemove = Set(indexSet.map { chapterPassages[$0].id })
                            editor.book.passages.removeAll { toRemove.contains($0.id) }
                        }
                    }
                }
                Section("New passage") {
                    TextField("Name (optional)", text: $name)
                    TextField("Start text", text: $startText)
                    TextField("End text", text: $endText)
                    if !error.isEmpty {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    Button("Verify") { verify() }
                    Button("Add") { add() }
                        .disabled(!verified)
                }
            }
            .onChange(of: startText) { _, _ in verified = false }
            .onChange(of: endText) { _, _ in verified = false }
            .navigationTitle("Passages")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func chapterPlainText() -> String {
        guard let chapter = editor.book.chapters.first(where: { $0.id == chapterId }) else { return "" }
        return PromptBuilder.chapterPlainText(chapter)
    }

    private func verify() {
        let full = chapterPlainText()
        let start = startText.trimmingCharacters(in: .whitespaces)
        let end = endText.trimmingCharacters(in: .whitespaces)
        guard let startRange = full.range(of: start), !start.isEmpty else {
            error = "Start text not found in chapter."; verified = false; return
        }
        guard full.range(of: end, range: startRange.upperBound..<full.endIndex) != nil, !end.isEmpty else {
            error = "End text not found after start text."; verified = false; return
        }
        error = ""
        verified = true
    }

    private func add() {
        guard verified else { return }
        let count = editor.book.passages.count
        editor.book.passages.append(Passage(
            name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Passage \(count + 1)" : name,
            chapterId: chapterId,
            startText: startText.trimmingCharacters(in: .whitespaces),
            endText: endText.trimmingCharacters(in: .whitespaces)
        ))
        name = ""; startText = ""; endText = ""; verified = false
    }
}
