import SwiftUI

/// The symbol and colour for a digest's state, in one place so the manuscript
/// badge and the summaries list can't drift apart.
struct DigestStatusIcon: View {
    let status: DigestStatus
    var size: CGFloat = 17

    var body: some View {
        Image(systemName: Self.symbol(status))
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Self.tint(status))
    }

    static func symbol(_ status: DigestStatus) -> String {
        switch status {
        // Not a wand: this button doesn't embellish anything, it extracts a
        // summary. The outline reads as the empty form the seal fills in.
        case .missing: return "list.bullet.rectangle"
        case .current: return "checkmark.seal.fill"
        case .stale: return "arrow.triangle.2.circlepath"
        case .editedCurrent: return "pencil.circle.fill"
        case .editedStale: return "exclamationmark.triangle.fill"
        }
    }

    static func tint(_ status: DigestStatus) -> Color {
        switch status {
        case .missing: return Theme.muted
        case .current: return Theme.accent
        case .stale: return Theme.accent
        case .editedCurrent: return Theme.ink
        case .editedStale: return Theme.danger
        }
    }

    static func accessibilityLabel(_ status: DigestStatus) -> String {
        switch status {
        case .missing: return String(localized: "Generate summary")
        case .current: return String(localized: "Show summary")
        case .stale: return String(localized: "Chapter changed — show summary")
        case .editedCurrent: return String(localized: "Summary edited by you — show")
        case .editedStale: return String(localized: "Chapter changed since you edited this summary")
        }
    }
}

/// The per-chapter digest button in the chapter list: a status badge that is
/// also the control. With no digest yet it generates one; once there is one,
/// it opens it — reading, editing and regenerating all happen in the sheet,
/// so a tap can never silently replace text the user has written.
struct ChapterDigestButton: View {
    @ObservedObject var store: ChapterDigestStore
    @ObservedObject var service: DigestService
    let chapter: Chapter
    /// Handed the current status so the caller can generate or open.
    let action: (DigestStatus) -> Void

    private var status: DigestStatus { store.status(for: chapter) }

    var body: some View {
        Button {
            action(status)
        } label: {
            DigestStatusIcon(status: status)
                .frame(width: 32, height: 32)
                .background(DigestStatusIcon.tint(status).opacity(0.12), in: Circle())
        }
        // Without `.borderless`, a `List` row treats any tap inside it as a
        // tap on the row's navigation link.
        .buttonStyle(.borderless)
        .disabled(service.isRunning)
        .opacity(service.isRunning ? 0.4 : 1)
        .accessibilityLabel(DigestStatusIcon.accessibilityLabel(status))
    }
}

/// Shown under the chapter-list header while a run is in progress. It is
/// deliberately not a modal or a blocking spinner: the job lives on
/// `AppEnvironment`, so the user is free to navigate away, keep writing, and
/// come back — this strip is a status report, not a cage.
struct DigestProgressBar: View {
    @ObservedObject var service: DigestService

    var body: some View {
        if let progress = service.progress {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Summaries \(progress.completed)/\(progress.total)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    if progress.failed > 0 {
                        Text("· \(progress.failed) failed")
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                    }
                    Spacer()
                    Button("Stop") { service.cancel() }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                }
                ProgressView(value: progress.fraction)
                    .tint(Theme.accent)
                if !progress.currentTitle.isEmpty {
                    Text(progress.currentTitle)
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.chrome)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line), alignment: .bottom)
        }
    }
}
