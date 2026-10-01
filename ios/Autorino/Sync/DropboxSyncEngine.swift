import Foundation

/// Two-way sync between `BookStore`'s local `Books/` folder and the root of
/// the Dropbox App folder. The algorithm and its never-lose-data rules live
/// in `FolderSyncEngine`; this wrapper adds the book-specific parts —
/// `SyncStatus` for the UI and reloading `BookStore` afterwards.
@MainActor
final class DropboxSyncEngine {
    private let auth: DropboxAuthService
    private let bookStore: BookStore
    private let status: SyncStatus
    private let engine: FolderSyncEngine

    init(auth: DropboxAuthService, bookStore: BookStore, status: SyncStatus) {
        self.auth = auth
        self.bookStore = bookStore
        self.status = status
        self.engine = FolderSyncEngine(
            client: DropboxClient(auth: auth),
            directory: { bookStore.booksDirectory },
            remoteFolder: "",
            syncIndex: bookStore.syncIndex,
            kind: .books,
            policy: .keepBoth
        )
    }

    func sync() async {
        guard auth.isConnected else { return }
        guard status.phase != .syncing else { return }
        status.phase = .syncing
        do {
            let conflicts = try await engine.sync()
            for name in conflicts where !status.conflicts.contains(name) {
                status.conflicts.append(name)
            }
            bookStore.reload()
            status.lastSyncedAt = Date()
            status.phase = .idle
        } catch {
            NSLog("[DropboxSync] sync failed: \(String(reflecting: error))")
            bookStore.reload()
            status.phase = .error(error.localizedDescription)
        }
    }
}
