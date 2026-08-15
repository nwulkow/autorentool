import SwiftUI

@main
struct AutorinoApp: App {
    @StateObject private var appEnvironment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appEnvironment)
                .onOpenURL { url in
                    appEnvironment.dropboxAuth.handleRedirect(url: url)
                }
                .task {
                    await appEnvironment.bootstrap()
                }
        }
    }
}
