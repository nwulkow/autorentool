import SwiftUI

@main
struct AutorinoApp: App {
    @StateObject private var appEnvironment = AppEnvironment()
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system

    init() {
        Theme.applyGlobalAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appEnvironment)
                // Separately, so views listing books observe the store itself:
                // `AppEnvironment` doesn't republish its services' changes.
                .environmentObject(appEnvironment.bookStore)
                .preferredColorScheme(appearanceMode.colorScheme)
                .onOpenURL { url in
                    appEnvironment.dropboxAuth.handleRedirect(url: url)
                }
                .task {
                    await appEnvironment.bootstrap()
                }
        }
    }
}
