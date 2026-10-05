import SwiftUI

/// "New version…" from the chapter editor: copy any existing version
/// (default V1, the main text) or start from an empty page. Mirrors the
/// web editor's version form (`createChapterVersion` in app.js).
struct NewVersionSheet: View {
    let chapter: Chapter
    let onCreate: (Chapter.VersionSource, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source: Chapter.VersionSource = .main
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Start from", selection: $source) {
                    Text(chapter.versionLabel(slot: nil)).tag(Chapter.VersionSource.main)
                    ForEach(chapter.versions) { version in
                        Text(chapter.versionLabel(slot: version.id)).tag(Chapter.VersionSource.version(version.id))
                    }
                    Text("Empty page").tag(Chapter.VersionSource.empty)
                }
                TextField("Name (optional)", text: $name)
            }
            .navigationTitle(String(format: String(localized: "New version V%lld"), chapter.nextVersionNumber))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(source, name.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
