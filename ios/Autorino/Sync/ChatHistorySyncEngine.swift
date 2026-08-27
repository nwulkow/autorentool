import Foundation

/// Two-way sync for `Documents/ChatHistory/*.json` against a `/ChatHistory/`
/// subfolder in the same Dropbox App folder `DropboxSyncEngine` already uses
/// for books — same client, same App folder, separate remote path and its
/// own `SyncIndexStore` so the two passes never step on each other's
/// bookkeeping (see `SyncIndexStore.indexFilename`).
///
/// Conflict policy deliberately differs from `DropboxSyncEngine`'s: a book
/// conflict is preserved as a separate `(Dropbox <date>)` file because either
/// side could hold irreplaceable prose. A chat transcript is just a list of
/// timestamped, uniquely-`id`'d turns, so when both sides changed since the
/// last sync the safe move is to union the two message lists rather than
/// pick a winner — nothing said in either conversation is lost, and the
/// merged transcript becomes the new synced state on both ends.
@MainActor
final class ChatHistorySyncEngine {
    private let auth: DropboxAuthService
    private let client: DropboxClient
    private let syncIndex: SyncIndexStore
    private let fileManager = FileManager.default

    init(auth: DropboxAuthService) {
        self.auth = auth
        self.client = DropboxClient(auth: auth)
        self.syncIndex = SyncIndexStore(indexFilename: "ChatHistorySyncIndex.json")
    }

    private var directory: URL { ChatHistoryStore.directory }
    private static let remoteFolder = "/ChatHistory"

    /// Reloads any `ChatHistoryStore` currently open in a view — there's at
    /// most a couple of these alive (the shared pane plus whatever's on
    /// screen), so a targeted callback list isn't worth the bookkeeping;
    /// callers that care re-read `messages` off the store they hold.
    func sync() async {
        guard auth.isConnected else { return }
        do {
            try await pullRemoteChanges()
            try await pushLocalChanges()
        } catch {
            NSLog("[ChatHistorySync] sync failed: \(String(reflecting: error))")
        }
    }

    // MARK: - Pull

    private func pullRemoteChanges() async throws {
        var allEntries: [DropboxEntry] = []
        var cursor = syncIndex.cursor
        var result = try await listCurrentFolder(cursor: cursor)
        allEntries += result.entries
        cursor = result.cursor
        while result.hasMore {
            result = try await client.listFolderContinue(cursor: cursor!)
            allEntries += result.entries
            cursor = result.cursor
        }

        var pendingError: Error?
        for entry in allEntries {
            guard entry.name.hasSuffix(".json") else { continue }
            let filename = entry.name
            do {
                if entry.isDeleted {
                    syncIndex.removeEntry(filename: filename) // never re-delete a local transcript from a remote wipe
                    continue
                }
                guard entry.isFile else { continue }
                let localRecord = syncIndex.entries[filename]
                guard localRecord?.contentHash != entry.contentHash else { continue }

                // Mirrors DropboxSyncEngine's pull gate: `isDirty` alone
                // isn't enough, since SyncIndexStore.isDirty defaults to
                // true for any filename it has never seen (e.g. a fresh
                // install with an empty index). Without also requiring the
                // local file to actually exist, every remote transcript on
                // first sync would route through mergeRemote against an
                // empty local list, then get marked dirty and re-uploaded
                // unnecessarily on the very next push.
                let localFileExists = fileManager.fileExists(atPath: directory.appendingPathComponent(filename).path)
                if syncIndex.isDirty(filename: filename) && localFileExists {
                    try await mergeRemote(filename: filename, entry: entry)
                } else {
                    try await downloadAndStore(filename: filename, entry: entry)
                }
            } catch {
                if pendingError == nil { pendingError = error }
            }
        }

        if let pendingError { throw pendingError }
        syncIndex.cursor = cursor
        syncIndex.persist()
    }

    /// `list_folder` reports a path that doesn't exist yet remotely (no
    /// device has pushed a transcript before) as a 409 with a
    /// `path/not_found` error tag in the body — Dropbox's convention for
    /// endpoint-specific errors, not a transport failure. Treated as "empty
    /// folder" rather than a hard failure, since that's the expected first
    /// run; any other 409 (or any other status) still propagates.
    private func listCurrentFolder(cursor: String?) async throws -> ListFolderResult {
        if let cursor { return try await client.listFolderContinue(cursor: cursor) }
        do {
            return try await client.listFolder(path: Self.remoteFolder)
        } catch DropboxAPIError.requestFailed(409, let body) where body.contains("path/not_found") {
            return ListFolderResult(entries: [], cursor: "", hasMore: false)
        }
    }

    private func downloadAndStore(filename: String, entry: DropboxEntry) async throws {
        let (data, downloaded) = try await client.download(path: "\(Self.remoteFolder)/\(filename)")
        try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        syncIndex.markSynced(filename: filename, rev: downloaded.rev, contentHash: downloaded.contentHash)
    }

    private func mergeRemote(filename: String, entry: DropboxEntry) async throws {
        let (data, downloaded) = try await client.download(path: "\(Self.remoteFolder)/\(filename)")
        // The Mac app writes `date` as an ISO-8601 string (server.py's
        // _llm_chat), which a default numeric-timestamp strategy fails to
        // parse — that failure, swallowed by the `try?` here, once treated
        // every Mac-authored transcript as empty and overwrote it on the next
        // push. `ChatMessage` now parses `date` itself (see its doc comment),
        // so any decoder works; `ChatMessage.decoder` stays as the one
        // deliberate entry point for transcript files.
        let remoteMessages = (try? ChatMessage.decoder.decode([ChatMessage].self, from: data)) ?? []
        let localURL = directory.appendingPathComponent(filename)
        let localMessages = (try? Data(contentsOf: localURL)).flatMap { try? ChatMessage.decoder.decode([ChatMessage].self, from: $0) } ?? []

        var byID: [String: ChatMessage] = [:]
        for message in remoteMessages { byID[message.id] = message }
        for message in localMessages { byID[message.id] = message } // local wins on an exact id clash (shouldn't happen — ids are uid()'d)
        let merged = byID.values.sorted { $0.date < $1.date }

        guard let mergedData = try? ChatMessage.encoder.encode(merged) else { return }
        try mergedData.write(to: localURL, options: .atomic)
        syncIndex.markSynced(filename: filename, rev: downloaded.rev, contentHash: downloaded.contentHash)
        syncIndex.markDirty(filename: filename) // merged copy still needs to go back up over the rev just recorded
    }

    // MARK: - Push

    private func pushLocalChanges() async throws {
        for filename in syncIndex.dirtyFilenames() {
            let record = syncIndex.entries[filename]
            let url = directory.appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: url) else { continue }
            let mode: DropboxClient.UploadMode = record?.rev.map { .update(rev: $0) } ?? .add
            do {
                let entry = try await client.upload(path: "\(Self.remoteFolder)/\(filename)", data: data, mode: mode)
                syncIndex.markSynced(filename: filename, rev: entry.rev, contentHash: entry.contentHash)
            } catch {
                continue // retried next pass, same as DropboxSyncEngine
            }
        }
    }

    /// Called right after a local append/clear so the new turn is queued for
    /// the next sync pass — mirrors `BookStore.save(markDirty:)` marking a
    /// book dirty on every edit.
    func markDirty(filename: String) {
        syncIndex.markDirty(filename: filename)
    }
}
