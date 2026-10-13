import Foundation

/// A conflict copy of a book left by sync, shown under its main book instead
/// of as a book of its own. The same rules live in `conflicts.py`:
///
///     <base> - Dropbox conflict <stamp>.json   remote side of a both-sides edit
///     <base> - local conflict <stamp>.json     local side on a device's first sync
///     <base> (Dropbox <stamp>).json            older copies, title left unchanged
///
/// A file is a conflict copy only while `<base>.json` exists and is readable;
/// otherwise it may be the only usable copy and stays an ordinary book.
/// Detection is by filename, so a copy whose title still equals the main
/// book's can't be mistaken for it.
///
/// Files are edited as raw JSON objects, never round-tripped through `Book`,
/// so fields this app doesn't model survive a resolution.
struct ConflictCopy: Identifiable {
    let filename: String
    /// The main book's file (the root, for a copy of a copy).
    let baseFilename: String
    let label: String
    let stamp: String
    /// `nil` when the file can't be parsed — it can then only be set aside.
    let object: [String: Any]?

    var id: String { filename }
}

enum BookConflicts {
    private static let patterns: [NSRegularExpression] = [
        #"^(.+) - (Dropbox conflict|local conflict) (\d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2})(?: \d+)?\.json$"#,
        #"^(.+) \((Dropbox) ([^)]*)\)\.json$"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// Whether the name has a conflict copy's shape, whatever exists.
    static func looksLikeCopy(_ filename: String) -> Bool {
        let range = NSRange(filename.startIndex..., in: filename)
        return patterns.contains { $0.firstMatch(in: filename, range: range) != nil }
    }

    static func classify(_ filename: String, existing: Set<String>) -> (base: String, label: String, stamp: String)? {
        let range = NSRange(filename.startIndex..., in: filename)
        for regex in patterns {
            guard let m = regex.firstMatch(in: filename, range: range),
                  let b = Range(m.range(at: 1), in: filename),
                  let l = Range(m.range(at: 2), in: filename),
                  let s = Range(m.range(at: 3), in: filename) else { continue }
            var base = String(filename[b]) + ".json"
            guard base != filename else { continue }
            // Walk up even when the middle copy is gone (already resolved).
            if let parent = classify(base, existing: existing) {
                base = parent.base
            } else if !existing.contains(base) {
                continue
            }
            return (base, String(filename[l]), String(filename[s]))
        }
        return nil
    }

    static func readObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func write(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    // MARK: - What differs

    struct ChapterDiff: Identifiable {
        enum Status { case changed, onlyCopy, onlyMain }
        let id: String
        let label: String
        let status: Status
        let mainWords: Int
        let copyWords: Int
    }

    struct OtherDiff: Identifiable {
        let key: String
        let onlyCopy: Int
        let onlyMain: Int
        let changed: Int
        var id: String { key }
    }

    struct Report {
        var chapters: [ChapterDiff] = []
        var other: [OtherDiff] = []
        var identical: Bool { chapters.isEmpty && other.isEmpty }
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return (a as AnyObject).isEqual(b)
        default: return false
        }
    }

    private static func chapters(_ book: [String: Any]) -> [[String: Any]] {
        book["chapters"] as? [[String: Any]] ?? []
    }

    static func report(main: [String: Any], copy: [String: Any]) -> Report {
        var report = Report()
        let mainCh = chapters(main), copyCh = chapters(copy)
        let mainById = Dictionary(mainCh.compactMap { c in (c["id"] as? String).map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
        let copyIds = Set(copyCh.compactMap { $0["id"] as? String })
        func name(_ c: [String: Any], _ i: Int) -> String {
            let label = [c["name"], c["label"]].compactMap { $0 as? String }.first { !$0.isEmpty } ?? ""
            return label.isEmpty ? "\(i + 1)" : "\(i + 1) – \(label)"
        }
        for (i, c) in copyCh.enumerated() {
            guard let id = c["id"] as? String else { continue }
            if let m = mainById[id] {
                if !same(m, c) {
                    report.chapters.append(.init(id: id, label: name(c, i), status: .changed, mainWords: words(m), copyWords: words(c)))
                }
            } else {
                report.chapters.append(.init(id: id, label: name(c, i), status: .onlyCopy, mainWords: 0, copyWords: words(c)))
            }
        }
        for (i, c) in mainCh.enumerated() {
            guard let id = c["id"] as? String, !copyIds.contains(id) else { continue }
            report.chapters.append(.init(id: id, label: name(c, i), status: .onlyMain, mainWords: words(c), copyWords: 0))
        }

        for key in Set(main.keys).union(copy.keys).sorted() where key != "chapters" && key != "title" {
            let a = main[key], b = copy[key]
            func idList(_ v: Any?) -> [String: Any]? {
                guard let list = (v ?? []) as? [[String: Any]] else { return nil }
                var out: [String: Any] = [:]
                for item in list {
                    guard let id = item["id"] as? String else { return nil }
                    out[id] = item
                }
                return out
            }
            if let am = idList(a), let bm = idList(b) {
                let onlyCopy = bm.keys.filter { am[$0] == nil }.count
                let onlyMain = am.keys.filter { bm[$0] == nil }.count
                let changed = bm.keys.filter { am[$0] != nil && !same(am[$0], bm[$0]) }.count
                if onlyCopy + onlyMain + changed > 0 {
                    report.other.append(.init(key: key, onlyCopy: onlyCopy, onlyMain: onlyMain, changed: changed))
                }
            } else if !same(a, b) {
                report.other.append(.init(key: key, onlyCopy: 0, onlyMain: 0, changed: 1))
            }
        }
        return report
    }

    static func paragraphs(_ html: String?) -> [String] {
        var text = html ?? ""
        text = text.replacingOccurrences(of: #"</(p|div|h[1-6]|li|blockquote)>|<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func words(_ chapter: [String: Any]) -> Int {
        paragraphs(chapter["content"] as? String).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).count
    }

    // MARK: - Paragraph diff

    enum DiffLine {
        enum Part { case same(String), del(String), add(String) }
        case same(count: Int)
        case del(String)
        case add(String)
        /// A removed paragraph paired with an added one: one edited paragraph
        /// with the changed words marked, so a small edit stays visible.
        case mod([Part])
    }

    private enum Op { case same(String), del(String), add(String) }

    private static func lcs(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        var table = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var out: [Op] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] { out.append(.same(a[i])); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { out.append(.del(a[i])); i += 1 }
            else { out.append(.add(b[j])); j += 1 }
        }
        while i < n { out.append(.del(a[i])); i += 1 }
        while j < m { out.append(.add(b[j])); j += 1 }
        return out
    }

    /// Splits into words with their trailing whitespace, so joining the
    /// parts back reproduces the paragraph.
    private static func tokens(_ s: String) -> [String] {
        var out: [String] = [], current = ""
        for ch in s {
            if ch.isWhitespace { current.append(ch) }
            else {
                if let last = current.last, last.isWhitespace { out.append(current); current = "" }
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func paragraphDiff(main: [String], copy: [String]) -> [DiffLine] {
        let ops = lcs(main, copy)
        var out: [DiffLine] = []
        var k = 0
        while k < ops.count {
            if case .same = ops[k] {
                if case .same(let count)? = out.last { out[out.count - 1] = .same(count: count + 1) }
                else { out.append(.same(count: 1)) }
                k += 1
                continue
            }
            var dels: [String] = [], adds: [String] = []
            while k < ops.count {
                if case .del(let t) = ops[k] { dels.append(t) }
                else if case .add(let t) = ops[k] { adds.append(t) }
                else { break }
                k += 1
            }
            let pairs = min(dels.count, adds.count)
            for p in 0..<pairs {
                let parts: [DiffLine.Part] = lcs(tokens(dels[p]), tokens(adds[p])).map {
                    switch $0 {
                    case .same(let t): return .same(t)
                    case .del(let t): return .del(t)
                    case .add(let t): return .add(t)
                    }
                }
                out.append(.mod(parts))
            }
            dels.dropFirst(pairs).forEach { out.append(.del($0)) }
            adds.dropFirst(pairs).forEach { out.append(.add($0)) }
        }
        return out
    }

    static func chapterParagraphs(_ book: [String: Any], id: String) -> [String] {
        paragraphs(chapters(book).first { $0["id"] as? String == id }?["content"] as? String)
    }

    // MARK: - Taking chapters

    /// Same rules as `conflicts.take_chapters`: a chapter the main book has
    /// is replaced (keeping alternative versions only the main book has), a
    /// chapter it lacks goes after the nearest chapter preceding it in the
    /// copy.
    static func takeChapters(_ ids: Set<String>, from copy: [String: Any], into main: inout [String: Any]) {
        let copyCh = chapters(copy)
        var result = chapters(main)
        func index(of id: Any?) -> Int? {
            guard let id = id as? String else { return nil }
            return result.firstIndex { $0["id"] as? String == id }
        }
        for (i, ch) in copyCh.enumerated() {
            guard let id = ch["id"] as? String, ids.contains(id) else { continue }
            var taken = ch
            if let idx = index(of: id) {
                let own = Set((taken["versions"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
                let extra = (result[idx]["versions"] as? [[String: Any]] ?? []).filter { !own.contains($0["id"] as? String ?? "") }
                if !extra.isEmpty {
                    taken["versions"] = (taken["versions"] as? [[String: Any]] ?? []) + extra
                }
                result[idx] = taken
                continue
            }
            var at = 0
            for prev in copyCh[..<i].reversed() {
                if let j = index(of: prev["id"]) { at = j + 1; break }
            }
            result.insert(taken, at: at)
        }
        main["chapters"] = result
        // A taken chapter that sat in the main book's bin is back in the book.
        if let bin = main["deleted_chapters"] as? [[String: Any]] {
            let kept = bin.filter { !ids.contains($0["id"] as? String ?? "") }
            if kept.count != bin.count {
                if kept.isEmpty { main.removeValue(forKey: "deleted_chapters") } else { main["deleted_chapters"] = kept }
            }
        }
    }
}

enum ConflictResolutionError: LocalizedError {
    case unreadable
    var errorDescription: String? {
        String(localized: "This version cannot be read. It can only be set aside (a copy stays in Backups).")
    }
}

/// Every resolution keeps a recoverable copy (CLAUDE.md, "Never lose a
/// book"): the main book is snapshotted before it changes, a set-aside copy
/// before its file is removed (and moved to the Dropbox Trash by the next
/// sync via `markDeleted`). A failed snapshot aborts.
extension BookStore {
    func conflicts(for book: Book) -> [ConflictCopy] {
        conflictCopies.filter { $0.baseFilename == book.filename }
    }

    func setAside(_ copy: ConflictCopy) throws {
        let url = booksDirectory.appendingPathComponent(copy.filename)
        try BackupStore.snapshot(url, kind: .books, reason: "conflict set aside")
        try FileManager.default.removeItem(at: url)
        syncIndex.markDeleted(filename: copy.filename)
        reload()
    }

    /// The copy's version becomes the main book (keeping the main title).
    func adopt(_ copy: ConflictCopy) throws {
        let mainURL = booksDirectory.appendingPathComponent(copy.baseFilename)
        guard var replacement = copy.object, let main = BookConflicts.readObject(mainURL) else {
            throw ConflictResolutionError.unreadable
        }
        replacement["title"] = main["title"]
        try BackupStore.snapshot(mainURL, kind: .books, reason: "before conflict resolved")
        try BookConflicts.write(replacement, to: mainURL)
        syncIndex.markDirty(filename: copy.baseFilename)
        try setAside(copy)
    }

    func takeChapters(_ ids: Set<String>, from copy: ConflictCopy) throws {
        let mainURL = booksDirectory.appendingPathComponent(copy.baseFilename)
        guard let source = copy.object, var main = BookConflicts.readObject(mainURL) else {
            throw ConflictResolutionError.unreadable
        }
        try BackupStore.snapshot(mainURL, kind: .books, reason: "before conflict merge")
        BookConflicts.takeChapters(ids, from: source, into: &main)
        try BookConflicts.write(main, to: mainURL)
        syncIndex.markDirty(filename: copy.baseFilename)
        reload()
    }
}
