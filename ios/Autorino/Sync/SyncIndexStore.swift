import Foundation

/// Per-file sync bookkeeping: what Dropbox revision/content-hash we last
/// synced, and whether the local copy has changed since. Persisted at
/// `Application Support/SyncIndex.json` — deliberately outside the Books
/// folder so it never gets swept up in book listing/import.
struct SyncEntry: Codable, Equatable {
    var rev: String?
    var contentHash: String?
    var dirty: Bool = false
    var deleted: Bool = false
    var lastSyncedAt: Date?
}

@MainActor
final class SyncIndexStore: ObservableObject {
    @Published private(set) var entries: [String: SyncEntry] = [:]
    @Published var cursor: String?

    private let fileManager = FileManager.default

    private var indexURL: URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if !fileManager.fileExists(atPath: support.path) {
            try? fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        }
        return support.appendingPathComponent("SyncIndex.json")
    }

    private struct Snapshot: Codable {
        var entries: [String: SyncEntry]
        var cursor: String?
    }

    init() {
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        entries = snapshot.entries
        cursor = snapshot.cursor
    }

    func persist() {
        let snapshot = Snapshot(entries: entries, cursor: cursor)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    func markDirty(filename: String) {
        var entry = entries[filename] ?? SyncEntry()
        entry.dirty = true
        entry.deleted = false
        entries[filename] = entry
        persist()
    }

    func markDeleted(filename: String) {
        var entry = entries[filename] ?? SyncEntry()
        entry.deleted = true
        entry.dirty = true
        entries[filename] = entry
        persist()
    }

    func markSynced(filename: String, rev: String?, contentHash: String?) {
        var entry = entries[filename] ?? SyncEntry()
        entry.rev = rev
        entry.contentHash = contentHash
        entry.dirty = false
        entry.deleted = false
        entry.lastSyncedAt = Date()
        entries[filename] = entry
        persist()
    }

    func removeEntry(filename: String) {
        entries.removeValue(forKey: filename)
        persist()
    }

    func isDirty(filename: String) -> Bool {
        entries[filename]?.dirty ?? true // unknown file counts as needing upload
    }

    func dirtyFilenames() -> [String] {
        entries.filter { $0.value.dirty }.map { $0.key }
    }
}
