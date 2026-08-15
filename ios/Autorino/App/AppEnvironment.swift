import Foundation
import Combine

/// Composition root — replaces the implicit "single Vue instance holds
/// everything" shape of `app.js` with a small set of injected services.
/// Held as a `@StateObject` in `AutorinoApp` and pushed into the
/// environment for every view to read.
@MainActor
final class AppEnvironment: ObservableObject {
    let bookStore: BookStore
    let dropboxAuth: DropboxAuthService
    let syncStatus: SyncStatus
    let syncEngine: DropboxSyncEngine
    let llmService: LLMService = GeminiLLMService()

    init() {
        let store = BookStore()
        let auth = DropboxAuthService()
        let status = SyncStatus()
        self.bookStore = store
        self.dropboxAuth = auth
        self.syncStatus = status
        self.syncEngine = DropboxSyncEngine(auth: auth, bookStore: store, status: status)
    }

    func bootstrap() async {
        guard dropboxAuth.isConnected else { return }
        await syncEngine.sync()
    }

    func syncNow() async {
        await syncEngine.sync()
    }
}
