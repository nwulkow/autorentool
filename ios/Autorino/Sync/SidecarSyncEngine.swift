import Foundation

/// Sync for the per-book sidecar folders that are not part of the shared
/// book format: `Documents/ChatHistory/` ⟷ `/ChatHistory` and
/// `Documents/Digests/` ⟷ `/Digests`. Same algorithm as books
/// (`FolderSyncEngine`), but a conflict is *merged* instead of kept twice —
/// a transcript is a list of uniquely-id'd turns and a digest file is one
/// record per chapter, so a union loses nothing. Mirrors `_merge_chat_messages`
/// and `_merge_digests` in the web app's `dropbox_sync.py`.
@MainActor
final class SidecarSyncEngine {
    private let auth: DropboxAuthService
    private let engine: FolderSyncEngine
    private let syncIndex: SyncIndexStore

    private init(auth: DropboxAuthService, directory: @escaping () -> URL, remoteFolder: String,
                 indexFilename: String, kind: BackupStore.Kind,
                 merge: @escaping (Data, Data) -> Data?) {
        self.auth = auth
        let index = SyncIndexStore(indexFilename: indexFilename)
        self.syncIndex = index
        self.engine = FolderSyncEngine(
            client: DropboxClient(auth: auth),
            directory: directory,
            remoteFolder: remoteFolder,
            syncIndex: index,
            kind: kind,
            policy: .merge(merge)
        )
    }

    static func chatHistory(auth: DropboxAuthService) -> SidecarSyncEngine {
        SidecarSyncEngine(auth: auth, directory: { ChatHistoryStore.directory }, remoteFolder: "/ChatHistory",
                          indexFilename: "ChatHistorySyncIndex.json", kind: .chatHistory,
                          merge: mergeChat)
    }

    static func digests(auth: DropboxAuthService) -> SidecarSyncEngine {
        SidecarSyncEngine(auth: auth, directory: { ChapterDigestStore.directory }, remoteFolder: "/Digests",
                          indexFilename: "DigestSyncIndex.json", kind: .digests,
                          merge: mergeDigests)
    }

    func sync() async {
        guard auth.isConnected else { return }
        do {
            _ = try await engine.sync()
        } catch {
            NSLog("[SidecarSync] sync failed: \(String(reflecting: error))")
        }
    }

    /// Queues a just-written file for the next pass. Change detection is by
    /// content hash anyway; the flag only makes intent visible in the index.
    func markDirty(filename: String) {
        syncIndex.markDirty(filename: filename)
    }

    // MARK: - Merges (nil = a side is unreadable; the engine then keeps local
    // and preserves the remote bytes in BackupStore)

    private static func decodeOrEmpty<T: Decodable>(_ type: T.Type, _ data: Data, _ decoder: JSONDecoder, empty: T) -> T? {
        if data.isEmpty { return empty }
        return try? decoder.decode(type, from: data)
    }

    /// Union by message id (local wins on an exact clash), sorted by date.
    /// The Mac app writes `date` as an ISO-8601 string; `ChatMessage`
    /// parses either form (see its doc comment).
    static func mergeChat(remote: Data, local: Data) -> Data? {
        guard let remoteMessages = decodeOrEmpty([ChatMessage].self, remote, ChatMessage.decoder, empty: []),
              let localMessages = decodeOrEmpty([ChatMessage].self, local, ChatMessage.decoder, empty: []) else { return nil }
        var byID: [String: ChatMessage] = [:]
        for message in remoteMessages { byID[message.id] = message }
        for message in localMessages { byID[message.id] = message }
        return try? ChatMessage.encoder.encode(byID.values.sorted { $0.date < $1.date })
    }

    /// Union of chapters; for a chapter on both sides, the more recently
    /// generated-or-edited digest.
    static func mergeDigests(remote: Data, local: Data) -> Data? {
        guard let remoteDigests = decodeOrEmpty([String: ChapterDigest].self, remote, ChapterDigestStore.decoder, empty: [:]),
              let localDigests = decodeOrEmpty([String: ChapterDigest].self, local, ChapterDigestStore.decoder, empty: [:]) else { return nil }
        var merged = remoteDigests
        for (chapterId, digest) in localDigests {
            let mine = digest.editedAt ?? digest.generatedAt
            if let other = merged[chapterId], (other.editedAt ?? other.generatedAt) > mine { continue }
            merged[chapterId] = digest
        }
        return try? ChapterDigestStore.encoder.encode(merged)
    }
}
