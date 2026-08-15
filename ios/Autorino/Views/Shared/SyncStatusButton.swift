import SwiftUI

/// Small, always-visible Dropbox sync control. Placed in the navigation bar
/// of the book list (`RootView`) and every tab of an open book
/// (`BookTabContainer`'s toolbar, which persists across `TabView` selection)
/// so sync is a single tap from anywhere instead of buried in Settings.
/// Settings still owns connect/disconnect/token entry — this is just the
/// status/trigger, mirroring the iOS-launch and pull-to-refresh sync paths
/// (see `AppEnvironment.bootstrap()`, `BookListView`'s `.refreshable`).
struct SyncStatusButton: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        if env.dropboxAuth.isConnected {
            Button {
                Task { await env.syncNow() }
            } label: {
                icon
            }
            .disabled(isSyncing)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    private var isSyncing: Bool {
        if case .syncing = env.syncStatus.phase { return true }
        return false
    }

    @ViewBuilder
    private var icon: some View {
        switch env.syncStatus.phase {
        case .syncing:
            ProgressView()
        case .error:
            Image(systemName: "exclamationmark.icloud.fill")
                .foregroundStyle(Theme.danger)
        case .idle:
            if !env.syncStatus.conflicts.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    private var accessibilityLabel: String {
        switch env.syncStatus.phase {
        case .syncing:
            return String(localized: "Syncing")
        case .error(let message):
            return message
        case .idle:
            return env.syncStatus.conflicts.isEmpty
                ? String(localized: "Sync now")
                : String(localized: "Sync conflicts — tap to review")
        }
    }
}
