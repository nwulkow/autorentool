import Foundation

/// Local safety net for everything a writer can lose — the iOS twin of the
/// web app's `backups.py`, same layout and rules.
///
/// Every code path that would overwrite or remove a book, chat transcript
/// or digest file (a save, a delete, a rename, a Dropbox pull) first copies
/// the current bytes here. The rule (CLAUDE.md, "Never lose a book"): no
/// user data is ever destroyed without a recoverable copy.
///
/// Layout: `Documents/Backups/<kind>/<base>/<yyyy-MM-dd HH.mm.ss> <reason>.json`.
/// Retention: everything from the last `keepAllFor`; older snapshots are
/// thinned to the newest one per calendar day, which is kept forever.
enum BackupStore {
    enum Kind: String {
        case books
        case chatHistory = "chat_history"
        case digests
    }

    struct Snapshot: Identifiable, Hashable {
        let url: URL
        let date: Date
        let reason: String
        let size: Int
        var id: URL { url }
    }

    struct BookBackups: Identifiable, Hashable {
        let base: String
        let snapshots: [Snapshot]  // newest first
        var id: String { base }
    }

    /// A routine save snapshots at most this often per book; destructive
    /// events (delete, rename, sync overwrite, shrink, unreadable) always do.
    static let routineInterval: TimeInterval = 15 * 60
    static let keepAllFor: TimeInterval = 14 * 24 * 3600

    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Backups", isDirectory: true)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()
    private static let stampLength = 19

    private static func directory(kind: Kind, base: String) -> URL {
        root.appendingPathComponent(kind.rawValue, isDirectory: true)
            .appendingPathComponent(base, isDirectory: true)
    }

    private static func date(of name: String) -> Date? {
        guard name.count >= stampLength else { return nil }
        return stampFormatter.date(from: String(name.prefix(stampLength)))
    }

    /// Snapshot filenames, oldest first.
    private static func snapshotNames(in dir: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && date(of: $0) != nil }.sorted()
    }

    /// Copies `url` into the store before the caller overwrites or removes
    /// it. No-op when there is no file, when it is identical to the newest
    /// snapshot, or for a `routine` save inside `routineInterval`.
    ///
    /// Throws on I/O failure on purpose: a destructive caller must not go
    /// ahead if its safety copy could not be written. Routine callers `try?`.
    static func snapshot(_ url: URL, kind: Kind, reason: String, routine: Bool = false) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let base = url.deletingPathExtension().lastPathComponent
        let dir = directory(kind: kind, base: base)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = snapshotNames(in: dir)
        let now = Date()
        if let newest = existing.last {
            if routine, let at = date(of: newest), now.timeIntervalSince(at) < routineInterval { return }
            if (try? Data(contentsOf: dir.appendingPathComponent(newest))) == data { return }
        }
        let stamp = stampFormatter.string(from: now)
        var dest = dir.appendingPathComponent("\(stamp) \(reason).json")
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(stamp) \(reason) \(n).json")
            n += 1
        }
        try data.write(to: dest, options: .atomic)
        prune(dir, now: now)
    }

    /// Like `snapshot`, for bytes that only exist in memory (e.g. a remote
    /// file sync could not merge). Always written, never deduplicated away.
    static func store(_ data: Data, kind: Kind, base: String, reason: String) throws {
        let dir = directory(kind: kind, base: base)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = stampFormatter.string(from: Date())
        var dest = dir.appendingPathComponent("\(stamp) \(reason).json")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(stamp) \(reason) \(n).json")
            n += 1
        }
        try data.write(to: dest, options: .atomic)
    }

    /// Older than `keepAllFor`: keep only the newest snapshot of each day.
    private static func prune(_ dir: URL, now: Date) {
        let calendar = Calendar.current
        var newestPerDay: [DateComponents: String] = [:]
        var old: [String] = []
        for name in snapshotNames(in: dir) {
            guard let at = date(of: name), now.timeIntervalSince(at) >= keepAllFor else { continue }
            old.append(name)
            newestPerDay[calendar.dateComponents([.year, .month, .day], from: at)] = name // ascending -> last wins
        }
        let keep = Set(newestPerDay.values)
        for name in old where !keep.contains(name) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    static func bookBackups() -> [BookBackups] {
        let booksRoot = root.appendingPathComponent(Kind.books.rawValue, isDirectory: true)
        let bases = (try? FileManager.default.contentsOfDirectory(atPath: booksRoot.path)) ?? []
        return bases.sorted().compactMap { base in
            let dir = booksRoot.appendingPathComponent(base, isDirectory: true)
            let snaps: [Snapshot] = snapshotNames(in: dir).reversed().compactMap { name in
                guard let at = date(of: name) else { return nil }
                let url = dir.appendingPathComponent(name)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                let reason = String(name.dropFirst(stampLength).dropLast(5)).trimmingCharacters(in: .whitespaces)
                return Snapshot(url: url, date: at, reason: reason, size: size)
            }
            return snaps.isEmpty ? nil : BookBackups(base: base, snapshots: snaps)
        }
    }

    /// True when `new` lost content relative to `old`: a chapter, character,
    /// location, note or event order gone, or the manuscript meaningfully
    /// shorter. That is what an accidental delete looks like from the save
    /// path, and it always earns a snapshot regardless of interval.
    /// Same thresholds as `backups.book_shrank`.
    static func bookShrank(from old: Book, to new: Book) -> Bool {
        if new.chapters.count < old.chapters.count
            || new.characters.count < old.characters.count
            || new.locations.count < old.locations.count
            || new.eventOrders.count < old.eventOrders.count
            || new.topics.count < old.topics.count
            || new.questions.count < old.questions.count
            || new.passages.count < old.passages.count
            || new.savedChats.count < old.savedChats.count {
            return true
        }
        let oldLen = old.chapters.reduce(0) { $0 + $1.content.count }
        let newLen = new.chapters.reduce(0) { $0 + $1.content.count }
        return oldLen > 2000 && newLen < oldLen - max(2000, oldLen / 20)
    }
}
