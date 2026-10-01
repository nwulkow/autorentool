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
    let chatSyncEngine: SidecarSyncEngine
    /// Chapter digests (`Documents/Digests`) ⟷ `/Digests`, so summaries
    /// generated here also reach the web app and other devices.
    let digestSyncEngine: SidecarSyncEngine
    let llmService: LLMService = GeminiLLMService()
    /// Owned here rather than by a view so a digest run survives navigation:
    /// a `Task` tied to a view's lifecycle dies the moment that view goes
    /// away, which would kill a whole-book rebuild the first time the user
    /// tapped anything. See `DigestService` for the rest of the reasoning.
    let digestService: DigestService

    init() {
        let store = BookStore()
        let auth = DropboxAuthService()
        let status = SyncStatus()
        self.bookStore = store
        self.dropboxAuth = auth
        self.syncStatus = status
        self.syncEngine = DropboxSyncEngine(auth: auth, bookStore: store, status: status)
        self.chatSyncEngine = SidecarSyncEngine.chatHistory(auth: auth)
        self.digestSyncEngine = SidecarSyncEngine.digests(auth: auth)
        self.digestService = DigestService(llm: llmService)
    }

    func bootstrap() async {
        guard dropboxAuth.isConnected else { return }
        await syncNow()
    }

    func syncNow() async {
        await syncEngine.sync()
        await chatSyncEngine.sync()
        await digestSyncEngine.sync()
        digestService.reloadStores()
    }
}
