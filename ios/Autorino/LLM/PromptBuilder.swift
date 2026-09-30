import Foundation

/// A chapter, passage, or character the user has picked to include as LLM
/// context. Chapter/passage mirrors app.js's `llmChapterSelected` entries
/// (`{id, type}`, app.js:566-598, 647-653); character mirrors
/// `llmSelectedCharIds` gated by `llmIncludeCharacters` (app.js:341-342,
/// 731-734, 765-766) — opt-in and per-character, not automatic.
struct ContentScopeItem: Identifiable, Hashable {
    enum Kind { case chapter, passage, character }
    var kind: Kind
    var id: String
}

/// Pure text-formatting helpers, ported from `classes.py`'s
/// `EventOrder.to_llm_prompt` and the chapter/passage plain-text and
/// content-scope logic scattered through app.js's LLM sections
/// (app.js:471-765). No I/O, no view dependency — same shape as today.
enum PromptBuilder {
    /// Mirrors `_chapterPlainText` (app.js:553-556): strips HTML tags and
    /// unescapes the handful of entities Quill emits.
    static func chapterPlainText(_ chapter: Chapter) -> String {
        htmlToPlainText(chapter.content)
    }

    static func htmlToPlainText(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Mirrors `_passagePlainText` (app.js:600-610): the substring between
    /// (and including) the passage's start/end anchor text, located in the
    /// parent chapter's plain text.
    static func passagePlainText(_ passage: Passage, chapters: [Chapter]) -> String {
        guard let chapter = chapters.first(where: { $0.id == passage.chapterId }) else { return "" }
        let full = chapterPlainText(chapter)
        guard !passage.startText.isEmpty, !passage.endText.isEmpty,
              let startRange = full.range(of: passage.startText) else { return "" }
        guard let endRange = full.range(of: passage.endText, range: startRange.upperBound..<full.endIndex) else { return "" }
        return String(full[startRange.lowerBound..<endRange.upperBound])
    }

    static func chapterDisplayName(_ chapterId: String, in chapters: [Chapter]) -> String {
        guard let idx = chapters.firstIndex(where: { $0.id == chapterId }) else { return "(unknown)" }
        let chapter = chapters[idx]
        let label = chapter.name.isEmpty ? chapter.label : chapter.name
        return label.isEmpty ? String(idx + 1) : "\(idx + 1) – \(label)"
    }

    static func passageDisplayName(_ passage: Passage, in chapters: [Chapter]) -> String {
        guard let idx = chapters.firstIndex(where: { $0.id == passage.chapterId }) else { return "✂ \(passage.name) (?)" }
        let chapter = chapters[idx]
        let label = chapter.name.isEmpty ? chapter.label : chapter.name
        let chLabel = label.isEmpty ? "Ch \(idx + 1)" : "Ch \(idx + 1) – \(label)"
        return "✂ \(passage.name) (\(chLabel))"
    }

    /// Concatenates the selected chapters/passages into the
    /// `--- label ---\ntext` blocks appended to a prompt (app.js:520-536,
    /// 647ff — the "include characters / chapter content" scope picker).
    /// Character items are excluded here — they go through
    /// `selectedCharacters`/`characterSystemInstruction` as a system
    /// instruction instead, matching `llmSelectedCharIds`'s handling
    /// (app.js:765-766).
    static func contentContextText(for items: [ContentScopeItem], book: Book) -> String {
        var parts: [String] = []
        for item in items {
            switch item.kind {
            case .chapter:
                guard let chapter = book.chapters.first(where: { $0.id == item.id }) else { continue }
                let text = chapterPlainText(chapter)
                guard !text.isEmpty else { continue }
                parts.append("--- \(chapterDisplayName(chapter.id, in: book.chapters)) ---\n\(text)")
            case .passage:
                guard let passage = book.passages.first(where: { $0.id == item.id }) else { continue }
                let text = passagePlainText(passage, chapters: book.chapters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                parts.append("--- \(passageDisplayName(passage, in: book.chapters)) ---\n\(text)")
            case .character:
                continue
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// One chapter's digest, ready to be written into a prompt. Staleness is
    /// resolved by the caller because it needs the store (and the main
    /// actor); `PromptBuilder` stays pure.
    struct DigestContextEntry {
        let index: Int
        let title: String
        let digest: ChapterDigest
        let isStale: Bool
    }

    /// The whole book as extracted notes — roughly 350 tokens a chapter
    /// against the ~8k its prose would cost, which is the only reason
    /// whole-book context is affordable on every turn.
    ///
    /// Field labels are English like the rest of the prompt scaffolding even
    /// though the content is the book's own language; the model reads the
    /// structure, and translating the labels would make the block disagree
    /// with `characterSystemInstruction` right next to it.
    /// `upToChapter` is 1-based and only affects the preamble — the caller
    /// has already filtered `entries`. It is stated to the model rather than
    /// applied silently: a model shown chapters 1-8 of 25 with no note will
    /// reason as though the book ends at 8, which is exactly the wrong answer
    /// to "how could this play out from here?".
    static func digestContextText(_ entries: [DigestContextEntry], upToChapter: Int? = nil, totalChapters: Int = 0) -> String {
        guard !entries.isEmpty else { return "" }
        var blocks: [String] = []
        for entry in entries {
            let d = entry.digest
            var header = "--- \(entry.index + 1) – \(entry.title)"
            // Said plainly rather than silently dropped: a summary whose
            // chapter has moved on is still the best available account of
            // that chapter, but the model must not treat it as current.
            if entry.isStale { header += " (summary predates the current chapter text)" }
            header += " ---"

            var lines: [String] = [header]
            var scene: [String] = []
            if !d.pov.isEmpty { scene.append("POV: \(d.pov)") }
            if !d.place.isEmpty { scene.append("Place: \(d.place)") }
            if !d.time.isEmpty { scene.append("Time: \(d.time)") }
            if !scene.isEmpty { lines.append(scene.joined(separator: " · ")) }
            if !d.present.isEmpty { lines.append("Present: \(d.present.joined(separator: ", "))") }
            if !d.summary.isEmpty { lines.append(d.summary) }
            for learn in d.learns where !learn.who.isEmpty || !learn.what.isEmpty {
                var line = "Learns: \(learn.who) — \(learn.what) [\(learn.certainty.rawValue)"
                if !learn.how.isEmpty { line += ", via \(learn.how)" }
                lines.append(line + "]")
            }
            if !d.established.isEmpty { lines.append("Established: \(d.established.joined(separator: "; "))") }
            if !d.devices.isEmpty { lines.append("Devices: \(d.devices.joined(separator: "; "))") }
            if !d.openThreads.isEmpty { lines.append("Open: \(d.openThreads.joined(separator: "; "))") }
            blocks.append(lines.joined(separator: "\n"))
        }
        var preamble = """
        --- Chapter summaries (the whole book, compressed) ---
        These are extracted notes, not the prose. "Learns" records who came to \
        know what and how, and whether it is confirmed or only suspected — use \
        it to work out who could plausibly know something at a given point. \
        Where an answer depends on actual wording, say which chapter's text you \
        would need.
        """
        if let upToChapter, totalChapters > upToChapter {
            preamble += "\nYou are being shown chapters 1-\(upToChapter) of \(totalChapters). "
                + "The later chapters exist and are deliberately withheld: answer as of chapter "
                + "\(upToChapter), and do not assume the story ends there."
        }
        return ([preamble] + blocks).joined(separator: "\n\n")
    }

    /// The characters picked in the scope picker, resolved against the
    /// book — mirrors `llmSelectedCharIds` filtered against `book.characters`
    /// (app.js:765-766).
    static func selectedCharacters(for items: [ContentScopeItem], book: Book) -> [Character] {
        let ids = Set(items.filter { $0.kind == .character }.map(\.id))
        guard !ids.isEmpty else { return [] }
        return book.characters.filter { ids.contains($0.id) }
    }

    /// Combines a base prompt/context (e.g. an event-order dump) with the
    /// selected chapters/passages, matching `runEoLlmPrompt`'s
    /// `[base, '', '--- Chapters / Passages ---', ...parts]` assembly
    /// (app.js:519-536).
    static func combinedText(base: String, scopeItems: [ContentScopeItem], book: Book) -> String {
        guard !scopeItems.isEmpty else { return base }
        let context = contentContextText(for: scopeItems, book: book)
        guard !context.isEmpty else { return base }
        return [base, "", "--- Chapters / Passages ---", context].joined(separator: "\n")
    }

    /// Mirrors `EventOrder.to_llm_prompt` (classes.py:91-112): a
    /// chronologically-sorted, human-readable dump of every event across
    /// all character columns.
    static func eventOrderPrompt(_ eventOrder: EventOrder, characters: [Character]) -> String {
        struct Row { let y: Double; let name: String; let desc: String; let time: String }
        var rows: [Row] = []
        for column in eventOrder.characterColumns {
            let name = characters.first(where: { $0.id == column.characterId })?.name ?? "General"
            for event in column.events {
                rows.append(Row(y: event.yPos, name: name, desc: event.description, time: event.time))
            }
        }
        rows.sort { $0.y < $1.y }
        var lines = ["Event Order: \(eventOrder.name)", ""]
        for row in rows {
            let timeStr = row.time.isEmpty ? "" : " [\(row.time)]"
            lines.append("- \(row.name)\(timeStr): \(row.desc)")
        }
        return lines.joined(separator: "\n")
    }

    /// Mirrors `chat_custom_prompt`'s `system_text` (llm_utils.py:111-112).
    static func characterSystemInstruction(_ characters: [Character]) -> String? {
        guard !characters.isEmpty else { return nil }
        let list = characters.map { "\($0.name) (\($0.description))" }.joined(separator: ", ")
        return "The following characters are present in the story: \(list)"
    }
}
