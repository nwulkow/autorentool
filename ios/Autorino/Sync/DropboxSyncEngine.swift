import Foundation

/// Two-way sync between `BookStore`'s local `Books/` folder and the
/// Dropbox App folder, using a persisted list-folder cursor for cheap
/// incremental passes. Runs on the main actor because it drives
/// `BookStore`/`SyncIndexStore`, both `@MainActor`; the network calls
/// themselves happen on `DropboxClient`, an actor, via `await`.
@MainActor
final class DropboxSyncEngine {
    private let auth: DropboxAuthService
    private let client: DropboxClient
    private let bookStore: BookStore
    private let syncIndex: SyncIndexStore
    private let status: SyncStatus

    init(auth: DropboxAuthService, bookStore: BookStore, status: SyncStatus) {
        self.auth = auth
        self.client = DropboxClient(auth: auth)
        self.bookStore = bookStore
        self.syncIndex = bookStore.syncIndex
        self.status = status
    }

    func sync() async {
        guard auth.isConnected else { return }
        guard status.phase != .syncing else { return }
        status.phase = .syncing
        do {
            try await pullRemoteChanges()
            try await pushLocalChanges()
            bookStore.reload()
            status.lastSyncedAt = Date()
            status.phase = .idle
        } catch {
            status.phase = .error(error.localizedDescription)
        }
    }

    // MARK: - Pull

    private func pullRemoteChanges() async throws {
        var allEntries: [DropboxEntry] = []
        var cursor = syncIndex.cursor
        var result = try cursor == nil
            ? await client.listFolder(path: "")
            : await client.listFolderContinue(cursor: cursor!)
        allEntries += result.entries
        cursor = result.cursor
        while result.hasMore {
            result = try await client.listFolderContinue(cursor: cursor!)
            allEntries += result.entries
            cursor = result.cursor
        }
        syncIndex.cursor = cursor
        syncIndex.persist()

        for entry in allEntries {
            guard entry.name.hasSuffix(".json") else { continue }
            let filename = entry.name

            if entry.isDeleted {
                try await handleRemoteDeletion(filename: filename)
                continue
            }
            guard entry.isFile else { continue }

            let localRecord = syncIndex.entries[filename]
            guard localRecord?.contentHash != entry.contentHash else { continue } // already in sync

            if syncIndex.isDirty(filename: filename) && bookStore.load(filename: filename) != nil {
                try await handleConflict(filename: filename, remoteEntry: entry)
            } else {
                try await downloadAndStore(filename: filename, entry: entry)
            }
        }
    }

    private func handleRemoteDeletion(filename: String) async throws {
        guard let record = syncIndex.entries[filename] else { return } // never synced here, nothing to remove
        if record.dirty {
            return // local edit in flight — next push will resurrect the file remotely
        }
        let url = bookStore.booksDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
        syncIndex.removeEntry(filename: filename)
    }

    private func downloadAndStore(filename: String, entry: DropboxEntry) async throws {
        let (data, downloaded) = try await client.download(path: "/" + filename)
        let url = bookStore.booksDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        syncIndex.markSynced(filename: filename, rev: downloaded.rev, contentHash: downloaded.contentHash)
    }

    /// Both the local file and the remote file changed since the last
    /// sync. Policy: never silently drop either side. The remote version
    /// is preserved as a separate `<title> (Dropbox <date>).json`, a
    /// conflict banner is surfaced, and the local edit proceeds to
    /// overwrite Dropbox on the following push (the index is caught up to
    /// the new remote rev so that push isn't itself rejected).
    private func handleConflict(filename: String, remoteEntry: DropboxEntry) async throws {
        let (data, downloaded) = try await client.download(path: "/" + filename)
        let base = filename.hasSuffix(".json") ? String(filename.dropLast(5)) : filename
        let stamp = Self.conflictDateFormatter.string(from: Date())
        let conflictURL = bookStore.booksDirectory.appendingPathComponent("\(base) (Dropbox \(stamp)).json")
        try data.write(to: conflictURL, options: .atomic)
        syncIndex.markSynced(filename: filename, rev: downloaded.rev, contentHash: downloaded.contentHash)
        syncIndex.markDirty(filename: filename) // keep local dirty so it re-uploads over the now-known rev
        if !status.conflicts.contains(filename) {
            status.conflicts.append(filename)
        }
    }

    // MARK: - Push

    private func pushLocalChanges() async throws {
        for filename in syncIndex.dirtyFilenames() {
            let record = syncIndex.entries[filename]
            if record?.deleted == true {
                try? await client.delete(path: "/" + filename)
                syncIndex.removeEntry(filename: filename)
                continue
            }
            let url = bookStore.booksDirectory.appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: url) else { continue }
            let mode: DropboxClient.UploadMode = record?.rev.map { .update(rev: $0) } ?? .add
            do {
                let entry = try await client.upload(path: "/" + filename, data: data, mode: mode)
                syncIndex.markSynced(filename: filename, rev: entry.rev, contentHash: entry.contentHash)
            } catch {
                // Leave dirty; retried on the next sync pass. One file
                // failing (e.g. a stale rev after a race) shouldn't abort
                // the rest of the push.
                continue
            }
        }
    }

    private static let conflictDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()
}
