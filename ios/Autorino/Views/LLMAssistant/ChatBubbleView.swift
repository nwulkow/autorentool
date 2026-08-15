import SwiftUI
import UIKit

/// One turn of the conversation. The assistant gets a marked avatar and a
/// paper-panel bubble, the writer gets an accent one — enough contrast to
/// read the transcript at a glance instead of as two near-identical grey
/// blocks.
struct ChatBubbleView: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isUser {
                Spacer(minLength: 44)
            } else {
                avatar
            }

            Text(message.content)
                .font(isUser ? .callout : Theme.serif(16, relativeTo: .callout))
                .foregroundStyle(isUser ? Color.white : Theme.ink)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleBackground)
                .clipShape(BubbleShape(pointingLeft: !isUser))
                .overlay(
                    BubbleShape(pointingLeft: !isUser)
                        .stroke(isUser ? Color.clear : Theme.line, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = message.content
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }

            if !isUser { Spacer(minLength: 44) }
        }
    }

    private var avatar: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(width: 26, height: 26)
            .background(Theme.accentSoft, in: Circle())
            .overlay(Circle().stroke(Theme.line, lineWidth: 1))
            .padding(.top, 2)
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if isUser {
            LinearGradient(
                colors: [Theme.accent, Theme.accent.opacity(0.86)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            Theme.panel
        }
    }
}

/// Rounded on three corners, tucked in on the one nearest its speaker —
/// the small asymmetry that makes a transcript read as a conversation.
struct BubbleShape: Shape {
    var pointingLeft: Bool
    var radius: CGFloat = 16
    var tuckedRadius: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        Path(
            UIBezierPath(
                roundedRect: rect,
                byRoundingCorners: pointingLeft
                    ? [.topRight, .bottomRight, .bottomLeft]
                    : [.topLeft, .bottomLeft, .bottomRight],
                cornerRadii: CGSize(width: radius, height: radius)
            ).cgPath
        )
        // Intersection, not union: each path rounds one set of corners and
        // leaves the rest square, so overlapping them is what keeps three
        // corners at `radius` and clips the fourth back to `tuckedRadius`.
        .intersection(
            Path(
                UIBezierPath(
                    roundedRect: rect,
                    byRoundingCorners: pointingLeft ? [.topLeft] : [.topRight],
                    cornerRadii: CGSize(width: tuckedRadius, height: tuckedRadius)
                ).cgPath
            )
        )
    }
}

/// The waiting state, in the same shape as an assistant reply so the answer
/// doesn't shift the layout when it lands.
struct ChatTypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 26, height: 26)
                .background(Theme.accentSoft, in: Circle())
                .overlay(Circle().stroke(Theme.line, lineWidth: 1))

            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Theme.muted)
                        .frame(width: 6, height: 6)
                        .opacity(animating ? 1 : 0.25)
                        .animation(
                            .easeInOut(duration: 0.6).repeatForever().delay(Double(index) * 0.18),
                            value: animating
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Theme.panel)
            .clipShape(BubbleShape(pointingLeft: true))
            .overlay(BubbleShape(pointingLeft: true).stroke(Theme.line, lineWidth: 1))

            Spacer(minLength: 44)
        }
        .onAppear { animating = true }
        .accessibilityLabel(Text("Thinking…"))
    }
}
