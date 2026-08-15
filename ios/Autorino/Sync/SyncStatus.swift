import Foundation

enum SyncPhase: Equatable {
    case idle
    case syncing
    case error(String)
}

@MainActor
final class SyncStatus: ObservableObject {
    @Published var phase: SyncPhase = .idle
    @Published var lastSyncedAt: Date?
    @Published var conflicts: [String] = []
}
