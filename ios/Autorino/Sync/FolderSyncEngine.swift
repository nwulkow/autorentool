import Foundation

/// Two-way sync of one local folder against one folder of the Dropbox App
/// folder. Books, chat transcripts and chapter digests are three instances
/// with different conflict policies; the web app's `dropbox_sync.py` runs
/// the same algorithm, so both sides must keep these rules in step.
///
/// NEVER-LOSE-DATA RULES (CLAUDE.md, "Never lose a book") — each one is
/// load-bearing:
/// - Change detection is by *content*: the local file's Dropbox
///   `content_hash` against the hash recorded at the last sync. A file that
///   differs counts as "changed here" whatever the dirty flag says — so a
///   lost flag, a reset index, or a book that fails to decode is never
///   overwritten.
/// - Before sync overwrites or removes a local file it goes to `BackupStore`.
/// - A book changed on both sides keeps both: the remote one becomes a new
///   book titled "<title> - Dropbox conflict <stamp>".
/// - Nothing is ever deleted on Dropbox. A book deleted in the app
///   (`markDeleted`) is *moved* to `/Trash`. A tracked file that vanished
///   locally without that mark is restored from Dropbox. Sidecars never
///   propagate deletion.
/// - A remote deletion only removes a local book unchanged since the last
///   sync (after a snapshot); a locally changed one is uploaded again.
@MainActor
final class FolderSyncEngine {
    enum Policy {
        /// Conflicting books are both kept.
        case keepBoth
        /// Conflicting sidecars are merged. `nil` = one side unreadable;
        /// local is then kept and the remote bytes go to `BackupStore`.
        case merge((_ remote: Data, _ local: Data) -> Data?)
    }

    let syncIndex: SyncIndexStore
    private let client: DropboxClient
    private let directory: () -> URL
    private let remoteFolder: String
    private let kind: BackupStore.Kind
    private let policy: Policy
    private let fileManager = FileManager.default

    static let trashFolder = "/Trash"

    init(client: DropboxClient, directory: @escaping () -> URL, remoteFolder: String,
         syncIndex: SyncIndexStore, kind: BackupStore.Kind, policy: Policy) {
        self.client = client
        self.directory = directory
        self.remoteFolder = remoteFolder
        self.syncIndex = syncIndex
        self.kind = kind
        self.policy = policy
    }

    /// One pull + push pass. Returns the filenames that conflicted (books
    /// only — merges resolve themselves).
    func sync() async throws -> [String] {
        var conflicts = try await pull()
        conflicts += try await push()
        return conflicts
    }

    private func remotePath(_ name: String) -> String {
        remoteFolder.isEmpty ? "/" + name : "\(remoteFolder)/\(name)"
    }

    // MARK: - Pull

    private func pull() async throws -> [String] {
        let (entries, cursor) = try await listChanges(cursor: syncIndex.cursor)
        var conflicts: [String] = []
        // The cursor only advances once every entry was handled: persisting
        // it earlier would skip a file whose download failed, forever.
        var pendingError: Error?
        for entry in entries where entry.name.hasSuffix(".json") {
            do {
                if try await handle(entry) { conflicts.append(entry.name) }
            } catch {
                if pendingError == nil { pendingError = error }
            }
        }
        if let pendingError { throw pendingError }
        syncIndex.cursor = cursor
        syncIndex.persist()
        return conflicts
    }

    /// An expired cursor (409 `reset`) falls back to a full listing — safe,
    /// because every decision is made from content hashes. A subfolder no
    /// device has pushed to yet (409 `path/not_found`) is empty.
    private func listChanges(cursor: String?) async throws -> ([DropboxEntry], String?) {
        var result: ListFolderResult
        do {
            if let cursor, !cursor.isEmpty {
                result = try await client.listFolderContinue(cursor: cursor)
            } else {
                result = try await client.listFolder(path: remoteFolder)
            }
        } catch DropboxAPIError.requestFailed(409, let body) where body.contains("reset") && cursor != nil {
            return try await listChanges(cursor: nil)
        } catch DropboxAPIError.requestFailed(409, let body) where body.contains("path/not_found") && !remoteFolder.isEmpty {
            return ([], nil)
        }
        var entries = result.entries
        while result.hasMore {
            result = try await client.listFolderContinue(cursor: result.cursor)
            entries += result.entries
        }
        return (entries, result.cursor)
    }

    /// Returns true when this entry produced a book conflict.
    private func handle(_ entry: DropboxEntry) async throws -> Bool {
        let name = entry.name
        let localURL = directory().appendingPathComponent(name)
        let record = syncIndex.entries[name]
        let localData = try? Data(contentsOf: localURL)
        let localHash = localData.map(DropboxClient.contentHash)
        let changedHere = localData != nil && (record == nil || record?.contentHash != localHash)

        if entry.isDeleted {
            guard record != nil else { return false }
            guard case .keepBoth = policy, localData != nil else {
                syncIndex.removeEntry(filename: name) // sidecars never delete locally
                return false
            }
            if changedHere {
                // Edited here after the other device deleted it: keep it and
                // upload it again as a new file.
                syncIndex.set(SyncEntry(rev: nil, contentHash: nil, dirty: true), for: name)
                return false
            }
            try BackupStore.snapshot(localURL, kind: kind, reason: "deleted on other device")
            try fileManager.removeItem(at: localURL)
            syncIndex.removeEntry(filename: name)
            return false
        }

        guard entry.isFile else { return false }
        if let localHash, localHash == entry.contentHash {
            syncIndex.markSynced(filename: name, rev: entry.rev, contentHash: entry.contentHash)
            return false
        }
        if let record, record.contentHash == entry.contentHash {
            return false // remote unchanged since last sync; push handles any local edit
        }

        let (data, downloaded) = try await client.download(path: remotePath(name))
        guard let localData else {
            try data.write(to: localURL, options: .atomic)
            syncIndex.markSynced(filename: name, rev: downloaded.rev, contentHash: downloaded.contentHash)
            return false
        }
        if !changedHere {
            try BackupStore.snapshot(localURL, kind: kind, reason: "before sync", routine: true)
            try data.write(to: localURL, options: .atomic)
            syncIndex.markSynced(filename: name, rev: downloaded.rev, contentHash: downloaded.contentHash)
            return false
        }
        switch policy {
        case .merge(let merge):
            try mergeOrPreserve(name: name, remote: data, localURL: localURL, localData: localData, merge: merge)
            syncIndex.markSynced(filename: name, rev: downloaded.rev, contentHash: downloaded.contentHash)
            syncIndex.markDirty(filename: name) // merged copy goes back up over the rev just recorded
            return false
        case .keepBoth where record == nil && remoteIsNewer(entry, than: localURL):
            // Never synced on this device (first connect) and Dropbox has the
            // newer version: that one keeps the main name, the local one
            // becomes a separate book. Both kept either way.
            try writeConflictCopy(of: name, data: localData, label: "local conflict")
            try BackupStore.snapshot(localURL, kind: kind, reason: "before sync")
            try data.write(to: localURL, options: .atomic)
            syncIndex.markSynced(filename: name, rev: downloaded.rev, contentHash: downloaded.contentHash)
            return true
        case .keepBoth:
            // Changed on both sides: local stays, remote becomes its own
            // book, and local is then uploaded over the now-known rev.
            try writeConflictCopy(of: name, data: data)
            syncIndex.markSynced(filename: name, rev: downloaded.rev, contentHash: downloaded.contentHash)
            syncIndex.markDirty(filename: name)
            return true
        }
    }

    /// Returns the bytes now on disk locally.
    @discardableResult
    private func mergeOrPreserve(name: String, remote: Data, localURL: URL, localData: Data,
                                 merge: (Data, Data) -> Data?) throws -> Data {
        try BackupStore.snapshot(localURL, kind: kind, reason: "before merge")
        guard let merged = merge(remote, localData) else {
            try BackupStore.store(remote, kind: kind, base: String(name.dropLast(5)), reason: "unmergeable remote")
            return localData
        }
        try merged.write(to: localURL, options: .atomic)
        return merged
    }

    /// Stores the remote side of a book conflict as a *separate book*: the
    /// title inside changes too, so both apps list it as its own entry (same
    /// title under a different filename would be hidden by `BookStore.reload`
    /// and saved over the original by the web app).
    private func remoteIsNewer(_ entry: DropboxEntry, than localURL: URL) -> Bool {
        guard let modified = entry.serverModified,
              let remote = ISO8601DateFormatter().date(from: modified),
              let local = (try? fileManager.attributesOfItem(atPath: localURL.path))?[.modificationDate] as? Date
        else { return false }
        return remote > local
    }

    private func writeConflictCopy(of name: String, data: Data, label: String = "Dropbox conflict") throws {
        let stamp = Self.conflictFormatter.string(from: Date())
        let base = String(name.dropLast(5))
        var payload = data
        let newBase: String
        if var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let oldTitle = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? base
            let title = "\(oldTitle) - \(label) \(stamp)"
            object["title"] = title
            newBase = String(Book.sanitizedFilename(for: title).dropLast(5))
            payload = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        } else {
            newBase = String(Book.sanitizedFilename(for: "\(base) - \(label) \(stamp)").dropLast(5))
        }
        var url = directory().appendingPathComponent(newBase + ".json")
        var n = 2
        while fileManager.fileExists(atPath: url.path) {
            url = directory().appendingPathComponent("\(newBase) \(n).json")
            n += 1
        }
        try payload.write(to: url, options: .atomic)
    }

    // MARK: - Push

    private func push() async throws -> [String] {
        var conflicts: [String] = []
        let dir = directory()
        let names = Set(((try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") })

        for name in names.sorted() {
            let url = dir.appendingPathComponent(name)
            guard var data = try? Data(contentsOf: url) else { continue }
            let record = syncIndex.entries[name]
            if let record, record.rev != nil, record.contentHash == DropboxClient.contentHash(data) {
                if record.dirty || record.deleted {
                    syncIndex.markSynced(filename: name, rev: record.rev, contentHash: record.contentHash)
                }
                continue // Dropbox already has exactly these bytes
            }
            let mode: DropboxClient.UploadMode = record?.rev.map { .update(rev: $0) } ?? .add
            do {
                let uploaded = try await client.upload(path: remotePath(name), data: data, mode: mode)
                syncIndex.markSynced(filename: name, rev: uploaded.rev, contentHash: uploaded.contentHash)
            } catch let error as DropboxAPIError where error.isConflict {
                // Dropbox holds a revision we never saw (e.g. a new local book
                // whose name already exists remotely). Same rules as a pull
                // conflict — never just overwrite it.
                let (remote, downloaded) = try await client.download(path: remotePath(name))
                switch policy {
                case .merge(let merge):
                    data = try mergeOrPreserve(name: name, remote: remote, localURL: url, localData: data, merge: merge)
                case .keepBoth:
                    if DropboxClient.contentHash(remote) != DropboxClient.contentHash(data) {
                        try writeConflictCopy(of: name, data: remote)
                        conflicts.append(name)
                    }
                }
                guard let rev = downloaded.rev else { continue }
                do {
                    let uploaded = try await client.upload(path: remotePath(name), data: data, mode: .update(rev: rev))
                    syncIndex.markSynced(filename: name, rev: uploaded.rev, contentHash: uploaded.contentHash)
                } catch {
                    syncIndex.set(SyncEntry(rev: rev, contentHash: downloaded.contentHash, dirty: true), for: name)
                }
            } catch {
                continue // transient; still differs, so retried next pass
            }
        }

        // Tracked files that are gone locally.
        for (name, record) in syncIndex.entries where !names.contains(name) {
            if record.deleted {
                if case .keepBoth = policy, record.rev != nil {
                    let stamp = Self.conflictFormatter.string(from: Date())
                    try await client.move(from: remotePath(name),
                                          to: "\(Self.trashFolder)/\(name.dropLast(5)) (deleted \(stamp)).json")
                }
                syncIndex.removeEntry(filename: name)
            } else if record.rev != nil {
                // Vanished without the app deleting it: that is data loss,
                // not intent — restore from Dropbox.
                do {
                    let (data, downloaded) = try await client.download(path: remotePath(name))
                    try data.write(to: dir.appendingPathComponent(name), options: .atomic)
                    syncIndex.markSynced(filename: name, rev: downloaded.rev, contentHash: downloaded.contentHash)
                } catch DropboxAPIError.requestFailed(409, let body) where body.contains("not_found") {
                    syncIndex.removeEntry(filename: name) // gone on both sides
                } catch {
                    continue // keep the record, retry next pass
                }
            } else {
                syncIndex.removeEntry(filename: name)
            }
        }
        return conflicts
    }

    private static let conflictFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f
    }()
}
