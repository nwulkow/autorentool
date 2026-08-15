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
