import SwiftUI

/// The pill under a book in the library that has conflict copies. Observes
/// the store itself so it disappears as soon as the last copy is resolved.
struct BookConflictBadge: View {
    @ObservedObject var store: BookStore
    let book: Book
    let action: () -> Void

    var body: some View {
        let count = store.conflicts(for: book).count
        if count > 0 {
            Button(action: action) {
                Label(count == 1
                      ? String(localized: "1 conflicting version · Review")
                      : String(localized: "\(count) conflicting versions · Review"),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.12), in: Capsule())
            }
            // Without `.borderless`, a tap anywhere in the row would go to
            // the book's navigation link instead.
            .buttonStyle(.borderless)
        }
    }
}

/// Compares each conflict copy with its main book and resolves it — the
/// same choices as the web app's conflict modal (`conflicts.py`). Nothing
/// here deletes: the main book is snapshotted before it changes, and a
/// copy that is set aside goes to Backups and the Dropbox Trash.
struct ConflictResolverView: View {
    @ObservedObject var store: BookStore
    let book: Book

    @Environment(\.dismiss) private var dismiss
    @State private var openDiffs: Set<String> = []
    @State private var error: String?
    @State private var pending: Pending?

    private enum Pending: Identifiable {
        case setAside(ConflictCopy), adopt(ConflictCopy)
        var id: String {
            switch self {
            case .setAside(let c): return "aside|" + c.filename
            case .adopt(let c): return "adopt|" + c.filename
            }
        }
    }

    private var copies: [ConflictCopy] { store.conflicts(for: book) }

    var body: some View {
        let main = BookConflicts.readObject(store.booksDirectory.appendingPathComponent(book.filename))
        NavigationStack {
            List {
                Section {
                    Text("Sync found other versions of this book. Take what you need from them into the main book, then set them aside. Nothing is deleted: set-aside versions stay in Backups and in the Dropbox Trash.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.danger)
                    }
                }
                ForEach(copies) { copy in
                    Section {
                        copySection(copy, main: main)
                    } header: {
                        Text(verbatim: "\(Self.label(copy)) · \(copy.stamp)")
                    }
                }
            }
            .navigationTitle("Conflicting versions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                pendingTitle,
                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                titleVisibility: .visible,
                presenting: pending
            ) { action in
                switch action {
                case .setAside(let copy):
                    Button("Set aside") { run { try store.setAside(copy) } }
                case .adopt(let copy):
                    Button("Use this whole version") { run { try store.adopt(copy) } }
                }
                Button("Cancel", role: .cancel) {}
            }
            .onChange(of: copies.isEmpty) { _, empty in
                if empty { dismiss() }
            }
        }
    }

    private var pendingTitle: String {
        switch pending {
        case .adopt: return String(localized: "Replace the main book with this version? The current main version is kept in Backups.")
        default: return String(localized: "Set this version aside? It stays in Backups and in the Dropbox Trash.")
        }
    }

    static func label(_ copy: ConflictCopy) -> String {
        switch copy.label {
        case "local conflict": return String(localized: "Version this device had before syncing")
        case "Dropbox conflict": return String(localized: "Version from the other device")
        default: return String(localized: "Older copy from Dropbox")
        }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
            openDiffs = []
        } catch {
            self.error = error.localizedDescription
        }
    }

    @ViewBuilder
    private func copySection(_ copy: ConflictCopy, main: [String: Any]?) -> some View {
        if let object = copy.object, let main {
            let report = BookConflicts.report(main: main, copy: object)
            if report.identical {
                Text("Identical to the main book.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            ForEach(report.chapters) { chapter in
                chapterRow(chapter, copy: copy, main: main, object: object)
            }
            if !report.other.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Other differences: \(report.other.map(Self.describe).joined(separator: " · "))")
                        .font(.footnote)
                    Text("Only taken over with “Use this whole version”.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
            }
            actions(copy, canAdopt: !report.identical)
        } else {
            Text("This version cannot be read. It can only be set aside (a copy stays in Backups).")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
            actions(copy, canAdopt: false)
        }
    }

    private func actions(_ copy: ConflictCopy, canAdopt: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                pending = .setAside(copy)
            } label: {
                Label("Keep main book, set this version aside", systemImage: "checkmark.circle")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderless)
            if canAdopt {
                Button {
                    pending = .adopt(copy)
                } label: {
                    Label("Use this whole version instead", systemImage: "arrow.uturn.backward.circle")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private static func describe(_ diff: BookConflicts.OtherDiff) -> String {
        let names = [
            "characters": String(localized: "Characters"), "relationships": String(localized: "Relations"),
            "locations": String(localized: "Locations"), "questions": String(localized: "Questions"),
            "passages": String(localized: "Passages"), "event_orders": String(localized: "Event orders"),
            "saved_chats": String(localized: "Saved chats"),
        ]
        var text = names[diff.key] ?? diff.key
        if diff.onlyCopy > 0 { text += " +\(diff.onlyCopy)" }
        if diff.onlyMain > 0 { text += " −\(diff.onlyMain)" }
        if diff.changed > 0 { text += " ~\(diff.changed)" }
        return text
    }

    private func chapterRow(_ chapter: BookConflicts.ChapterDiff, copy: ConflictCopy, main: [String: Any], object: [String: Any]) -> some View {
        let key = copy.filename + "|" + chapter.id
        return VStack(alignment: .leading, spacing: 6) {
            Text(chapter.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
            HStack(spacing: 8) {
                statusPill(chapter.status)
                Text(wordsText(chapter))
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            if chapter.status != .onlyMain {
                HStack(spacing: 16) {
                    if chapter.status == .changed {
                        Button(openDiffs.contains(key) ? "Hide differences" : "Show differences") {
                            if openDiffs.contains(key) { openDiffs.remove(key) } else { openDiffs.insert(key) }
                        }
                        .buttonStyle(.borderless)
                    }
                    Button(chapter.status == .changed ? "Use this text" : "Add to main book") {
                        run { try store.takeChapters([chapter.id], from: copy) }
                    }
                    .buttonStyle(.borderless)
                }
                .font(.footnote.weight(.medium))
            }
            if openDiffs.contains(key) {
                DiffView(lines: BookConflicts.paragraphDiff(
                    main: BookConflicts.chapterParagraphs(main, id: chapter.id),
                    copy: BookConflicts.chapterParagraphs(object, id: chapter.id)
                ))
            }
        }
        .padding(.vertical, 2)
    }

    private func wordsText(_ chapter: BookConflicts.ChapterDiff) -> String {
        switch chapter.status {
        case .changed: return String(localized: "\(chapter.mainWords) → \(chapter.copyWords) words")
        case .onlyCopy: return String(localized: "\(chapter.copyWords) words")
        case .onlyMain: return String(localized: "\(chapter.mainWords) words")
        }
    }

    private func statusPill(_ status: BookConflicts.ChapterDiff.Status) -> some View {
        let (text, color): (String, Color) = switch status {
        case .changed: (String(localized: "different text"), Theme.accent)
        case .onlyCopy: (String(localized: "only in this version"), .green)
        case .onlyMain: (String(localized: "missing in this version"), Theme.muted)
        }
        return Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// Paragraph diff: red is the main book, green this version; an edited
/// paragraph shows both inline with the changed words marked.
private struct DiffView: View {
    let lines: [BookConflicts.DiffLine]

    private static let removed = Color.red.opacity(0.12)
    private static let added = Color.green.opacity(0.15)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("main book").padding(.horizontal, 6).background(Self.removed, in: Capsule())
                Text("this version").padding(.horizontal, 6).background(Self.added, in: Capsule())
            }
            .font(.caption2)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                switch line {
                case .same(let count):
                    Text(count == 1 ? String(localized: "… 1 unchanged paragraph …") : String(localized: "… \(count) unchanged paragraphs …"))
                        .italic()
                        .foregroundStyle(Theme.muted)
                case .del(let text):
                    Text(text).padding(4).frame(maxWidth: .infinity, alignment: .leading).background(Self.removed)
                case .add(let text):
                    Text(text).padding(4).frame(maxWidth: .infinity, alignment: .leading).background(Self.added)
                case .mod(let parts):
                    Text(Self.attributed(parts))
                        .padding(4)
                        .overlay(Rectangle().frame(width: 3).foregroundStyle(Color.orange.opacity(0.5)), alignment: .leading)
                }
            }
        }
        .font(.caption)
        .textSelection(.enabled)
        .padding(8)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
    }

    private static func attributed(_ parts: [BookConflicts.DiffLine.Part]) -> AttributedString {
        var out = AttributedString()
        for part in parts {
            switch part {
            case .same(let t):
                out += AttributedString(t)
            case .del(let t):
                var a = AttributedString(t)
                a.backgroundColor = removed
                a.strikethroughStyle = .single
                out += a
            case .add(let t):
                var a = AttributedString(t)
                a.backgroundColor = added
                out += a
            }
        }
        return out
    }
}
