import SwiftUI

/// New-character sheet. Mirrors `addCharacter` (app.js:948-953).
struct CharacterEditSheet: View {
    @ObservedObject var editor: BookEditor
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Description", text: $description, axis: .vertical)
            }
            .navigationTitle("New Character")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        editor.book.characters.append(Character(name: name.trimmingCharacters(in: .whitespaces), description: description.trimmingCharacters(in: .whitespaces)))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
