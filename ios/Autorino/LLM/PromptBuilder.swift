import Foundation

/// A chapter or passage the user has picked to include as LLM context —
/// mirrors app.js's `llmChapterSelected` entries (`{id, type}`,
/// app.js:566-598, 647-653).
struct ContentScopeItem: Identifiable, Hashable {
    enum Kind { case chapter, passage }
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
            }
        }
        return parts.joined(separator: "\n\n")
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
