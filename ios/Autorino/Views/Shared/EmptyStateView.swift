import SwiftUI

/// Mirrors `.empty-state` (styles.css:172) — a quiet, warm prompt rather
/// than the stark system placeholder.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(Theme.muted.opacity(0.55))

            Text(title)
                .font(Theme.sectionTitle)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)

            if !message.isEmpty {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
    }
}

struct PlaceholderTabView: View {
    let title: String
    let systemImage: String
    let note: String

    var body: some View {
        EmptyStateView(
            systemImage: systemImage,
            title: title,
            message: note
        )
    }
}
