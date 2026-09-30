import SwiftUI

/// Which chapter's digest a sheet is showing. `chapter.id` is the identity
/// because a digest belongs to a chapter, not to a position — reordering the
/// manuscript must not swap two summaries around.
struct DigestTarget: Identifiable {
    let index: Int
    let chapter: Chapter
    var id: String { chapter.id }
}

/// Every chapter's summary in one list — the answer to "where do I read
/// these?". The per-chapter badge in the manuscript opens one directly; this
/// screen is for going through them, which is how a continuity check
/// actually gets done.
struct DigestListView: View {
    @ObservedObject var editor: BookEditor
    @EnvironmentObject private var env: AppEnvironment
    @State private var editing: DigestTarget?

    private var store: ChapterDigestStore { env.digestService.store(for: editor.book.title) }

    var body: some View {
        VStack(spacing: 0) {
            if env.digestService.progress != nil {
                DigestProgressBar(service: env.digestService)
            }
            content
        }
        .background(Theme.paper)
        .navigationTitle("Summaries")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { target in
            DigestEditorSheet(
                store: store,
                service: env.digestService,
                editor: editor,
                index: target.index,
                chapter: target.chapter
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if editor.book.chapters.isEmpty {
            EmptyStateView(
                systemImage: "list.bullet.rectangle",
                title: String(localized: "No chapters yet."),
                message: String(localized: "Summaries are made from chapters — add one first.")
            )
        } else {
            List {
                ForEach(Array(editor.book.chapters.enumerated()), id: \.element.id) { index, chapter in
                    Button {
                        if store.digest(for: chapter.id) == nil {
                            env.digestService.generate(chapter: chapter, index: index, in: editor.book)
                        } else {
                            editing = DigestTarget(index: index, chapter: chapter)
                        }
                    } label: {
                        row(index: index, chapter: chapter)
                    }
                    .buttonStyle(.plain)
                    .bookCardRow()
                }
            }
            .listStyle(.plain)
            .paperBackground()
        }
    }

    private func row(index: Int, chapter: Chapter) -> some View {
        let digest = store.digest(for: chapter.id)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(DigestService.displayTitle(chapter, index: index))
                    .font(Theme.rowTitle)
                    .foregroundStyle(Theme.ink)
                if let digest, !digest.summary.isEmpty {
                    Text(digest.summary)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(3)
                } else if digest == nil {
                    Text("No summary yet — tap to generate one.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                if let digest, !digest.learns.isEmpty {
                    Text("\(digest.learns.count) findings")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            Spacer(minLength: 0)
            DigestStatusIcon(status: store.status(for: chapter))
        }
        .bookCard(padding: 14)
    }
}

/// View and correct one chapter's digest.
///
/// Editing matters more here than it looks: a digest is cached and every
/// later idea prompt reads it, so one wrong `learns` entry — a character
/// credited with knowing something they only suspect — quietly skews every
/// answer built on top of it. Saving a change stamps `editedAt`, which takes
/// the record out of the cache and makes it the user's, so no bulk rebuild
/// can overwrite it afterwards.
struct DigestEditorSheet: View {
    @ObservedObject var store: ChapterDigestStore
    @ObservedObject var service: DigestService
    @ObservedObject var editor: BookEditor
    let index: Int
    let chapter: Chapter

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ChapterDigest?
    /// What was on disk when the sheet opened. Compared on save so merely
    /// *looking* at a digest never marks it hand-edited — that flag is what
    /// excludes it from bulk runs, and it should mean something.
    @State private var original: ChapterDigest?
    @State private var confirmingRegenerate = false

    var body: some View {
        NavigationStack {
            Group {
                if let bound = Binding($draft) {
                    form(bound)
                } else {
                    EmptyStateView(
                        systemImage: "list.bullet.rectangle",
                        title: String(localized: "No summary yet."),
                        message: String(localized: "Generate one from the manuscript list.")
                    )
                }
            }
            .navigationTitle("Chapter \(index + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(draft == nil || draft == original)
                }
            }
            .confirmationDialog(
                "Regenerate summary?",
                isPresented: $confirmingRegenerate,
                titleVisibility: .visible
            ) {
                Button("Regenerate", role: .destructive) {
                    service.generate(chapter: chapter, index: index, in: editor.book)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The model writes a new summary from the chapter as it stands now. This version is discarded.")
            }
        }
        .onAppear(perform: load)
        // A regenerate started from this sheet lands in the store, not in
        // `draft` — pick it up so the user sees the new text without having
        // to close and reopen.
        .onChange(of: store.digest(for: chapter.id)?.generatedAt) { _, _ in load() }
    }

    private func load() {
        let stored = store.digest(for: chapter.id)
        draft = stored
        original = stored
    }

    private func save() {
        guard let draft, draft != original else { return dismiss() }
        store.saveEdited(trimmed(draft))
        dismiss()
    }

    /// Empty rows are how an editable list looks mid-edit, not something the
    /// prompt should carry.
    private func trimmed(_ digest: ChapterDigest) -> ChapterDigest {
        var out = digest
        func clean(_ list: [String]) -> [String] {
            list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        out.present = clean(out.present)
        out.established = clean(out.established)
        out.devices = clean(out.devices)
        out.openThreads = clean(out.openThreads)
        out.unknownNames = clean(out.unknownNames)
        out.learns = out.learns.filter {
            !($0.who + $0.what).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return out
    }

    @ViewBuilder
    private func form(_ digest: Binding<ChapterDigest>) -> some View {
        Form {
            Section {
                TextField("Summary", text: digest.summary, axis: .vertical)
                    .lineLimit(4...14)
            } header: {
                Text(chapter.name.isEmpty ? chapter.label : chapter.name)
            }

            Section("Scene") {
                // Stacked rather than label-and-value: a place like
                // "Krankenhaus Oldenburg, Intensivstation" squeezes a
                // trailing field down to nothing.
                FieldRow(label: "Point of view", text: digest.pov)
                FieldRow(label: "Place", text: digest.place)
                FieldRow(label: "Time", text: digest.time)
            }

            StringListSection(title: "Present", placeholder: "Name", items: digest.present)

            learnsSection(digest.learns)

            StringListSection(title: "Established facts", placeholder: "Fact", items: digest.established)
            StringListSection(title: "Devices", placeholder: "Device", items: digest.devices)
            StringListSection(title: "Open threads", placeholder: "Thread", items: digest.openThreads)
            StringListSection(title: "Unknown names", placeholder: "Name", items: digest.unknownNames)

            Section {
                Button {
                    confirmingRegenerate = true
                } label: {
                    if service.isRunning {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Generating…")
                        }
                    } else {
                        Label("Regenerate", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(service.isRunning)
            } footer: {
                provenance(digest.wrappedValue)
            }
        }
        .paperBackground()
    }

    /// The load-bearing section: who came to know what, and how. Certainty is
    /// a control rather than free text because the difference between knowing
    /// and suspecting is usually the plot.
    @ViewBuilder
    private func learnsSection(_ learns: Binding<[ChapterDigest.Learn]>) -> some View {
        Section("Who learns what") {
            ForEach(learns.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Who", text: learns[i].who)
                        .font(.body.weight(.semibold))
                    TextField("What", text: learns[i].what, axis: .vertical)
                    TextField("How", text: learns[i].how, axis: .vertical)
                        .foregroundStyle(Theme.muted)
                    Picker("Certainty", selection: learns[i].certainty) {
                        ForEach(ChapterDigest.Learn.Certainty.allCases, id: \.self) { value in
                            Text(value.label).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.vertical, 4)
            }
            .onDelete { learns.wrappedValue.remove(atOffsets: $0) }
            Button {
                learns.wrappedValue.append(ChapterDigest.Learn())
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
    }

    private func provenance(_ digest: ChapterDigest) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let editedAt = digest.editedAt {
                Text("Edited by you \(editedAt.formatted(date: .abbreviated, time: .shortened))")
            }
            Text("Generated \(digest.generatedAt.formatted(date: .abbreviated, time: .shortened)) · \(digest.generatedBy)")
            if store.status(for: chapter).isStale {
                Text("The chapter has changed since this was made.")
                    .foregroundStyle(Theme.danger)
            }
        }
        .font(.caption2)
    }
}

/// A caption above a full-width field, so long values stay readable.
private struct FieldRow: View {
    let label: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.muted)
            TextField(label, text: $text, axis: .vertical)
        }
        .padding(.vertical, 2)
    }
}

/// One row per string, plus an add button. Used for the digest's five plain
/// lists so they're all editable the same way.
private struct StringListSection: View {
    let title: LocalizedStringKey
    let placeholder: LocalizedStringKey
    @Binding var items: [String]

    var body: some View {
        Section(title) {
            ForEach(items.indices, id: \.self) { i in
                TextField(placeholder, text: $items[i], axis: .vertical)
            }
            .onDelete { items.remove(atOffsets: $0) }
            Button {
                items.append("")
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
    }
}
