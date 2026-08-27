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
    /// Distinguishes this index's file from another `SyncIndexStore`
    /// instance's — `ChatHistorySyncEngine` keeps its own bookkeeping
    /// separate from `DropboxSyncEngine`'s, since a chat-history filename
    /// and a book filename are both derived from the same title and would
    /// otherwise collide as the same key pointing at two different remote
    /// paths.
    private let indexFilename: String

    private var indexURL: URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if !fileManager.fileExists(atPath: support.path) {
            try? fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        }
        return support.appendingPathComponent(indexFilename)
    }

    private struct Snapshot: Codable {
        var entries: [String: SyncEntry]
        var cursor: String?
    }

    init(indexFilename: String = "SyncIndex.json") {
        self.indexFilename = indexFilename
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

    /// Wipes the cursor and all per-file bookkeeping so the next sync does a
    /// full fresh `list_folder` and re-evaluates every remote file from
    /// scratch. Doesn't touch local books or the Dropbox connection — only
    /// this app's memory of what it already synced. Needed as a manual
    /// escape hatch because a cursor can end up pointing past files that
    /// were never actually downloaded (e.g. after a transient failure mid
    /// batch on an older build); the fix keeps that from happening on new
    /// syncs, but can't retroactively repair a cursor that already moved.
    func reset() {
        entries = [:]
        cursor = nil
        persist()
    }
}
