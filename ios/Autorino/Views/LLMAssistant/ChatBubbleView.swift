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

            bubble
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

    /// One `Text` per Markdown block instead of one for the whole reply —
    /// see `ChatMarkdown` for why a single `AttributedString` can't do this.
    private var bubble: some View {
        VStack(alignment: .leading, spacing: 7) {
            if message.usedBookText == false { noBookTextTag }
            ForEach(ChatMarkdown.blocks(in: message.content)) { block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Says, on the reply itself, that this answer was produced without the
    /// manuscript in the prompt — otherwise a transcript read back a week
    /// later gives no way to tell an ungrounded answer from a grounded one.
    private var noBookTextTag: some View {
        Text("Did not use book text")
            .font(.caption2.weight(.medium))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.chrome, in: Capsule())
            .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
    }

    @ViewBuilder
    private func blockView(_ block: ChatMarkdown.Block) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(ChatMarkdown.inline(block.text))
                .font(.system(size: level <= 2 ? 17 : 15, weight: .semibold))
                .padding(.top, 2)
        case .bullet:
            listRow(marker: "•", text: block.text)
        case .numbered(let marker):
            listRow(marker: marker, text: block.text)
        case .quote:
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .frame(width: 2)
                    .foregroundStyle(isUser ? Color.white.opacity(0.5) : Theme.line)
                Text(ChatMarkdown.inline(block.text))
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code:
            Text(block.text)
                .font(.system(size: 13, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isUser ? Color.white.opacity(0.15) : Theme.chrome, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .paragraph:
            Text(ChatMarkdown.inline(block.text))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(marker)
                .fontWeight(.semibold)
            Text(ChatMarkdown.inline(text))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
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

/// Just enough Markdown to render an LLM reply legibly.
///
/// The previous approach — one `AttributedString(markdown:)` with
/// `interpretedSyntax: .full` — parsed headings and lists but SwiftUI's
/// `Text` then flattened the whole document into a single run: every
/// paragraph, bullet and heading ran together with no line breaks anywhere.
/// The fix is to split blocks here and lay each one out as its own view,
/// handing `AttributedString` only *inline* syntax (`**bold**`, `_italic_`,
/// `` `code` ``), which `Text` does render correctly.
enum ChatMarkdown {
    struct Block: Identifiable {
        enum Kind: Hashable {
            case heading(Int)
            case bullet
            case numbered(String)
            case quote
            case code
            case paragraph
        }

        let id = UUID()
        let kind: Kind
        let text: String
    }

    /// `.inlineOnlyPreservingWhitespace`, not `.inlineOnly`: a soft line
    /// break inside one block (a list item wrapped over two lines, say) must
    /// survive as a real newline instead of being collapsed to a space.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    static func blocks(in raw: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var inCode = false

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph.removeAll()
            if !joined.isEmpty { blocks.append(Block(kind: .paragraph, text: joined)) }
        }

        for rawLine in sanitized(raw).components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(Block(kind: .code, text: codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                } else {
                    flushParagraph()
                }
                inCode.toggle()
                continue
            }
            if inCode { codeLines.append(rawLine); continue }

            if line.isEmpty { flushParagraph(); continue }

            if let (level, body) = heading(line) {
                flushParagraph()
                blocks.append(Block(kind: .heading(level), text: body))
                continue
            }
            // A `---`/`***` rule has no separate visual here — the block
            // spacing already separates sections, so it's simply dropped
            // rather than shown as literal dashes.
            if isRule(line) { flushParagraph(); continue }
            if let body = bullet(line) {
                flushParagraph()
                blocks.append(Block(kind: .bullet, text: body))
                continue
            }
            if let (marker, body) = numbered(line) {
                flushParagraph()
                blocks.append(Block(kind: .numbered(marker), text: body))
                continue
            }
            if line.hasPrefix(">") {
                flushParagraph()
                blocks.append(Block(kind: .quote, text: String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }
            paragraph.append(line)
        }

        if inCode, !codeLines.isEmpty {
            blocks.append(Block(kind: .code, text: codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    /// Models occasionally wrap a phrase in LaTeX math delimiters (`$…$`,
    /// `\(…\)`) even in plain prose, and nothing here renders LaTeX — the
    /// writer just sees stray `$` characters mid-sentence. A novel assistant
    /// has no use for math markup, so the delimiters are dropped and their
    /// contents kept.
    static func sanitized(_ raw: String) -> String {
        var text = raw
        for pattern in [#"\$\$(.+?)\$\$"#, #"\$(.+?)\$"#, #"\\\((.+?)\\\)"#, #"\\\[(.+?)\\\]"#] {
            text = text.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        }
        return text
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes > 0, hashes <= 6, line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return (hashes, String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        line.count >= 3 && (line.allSatisfy { $0 == "-" } || line.allSatisfy { $0 == "*" } || line.allSatisfy { $0 == "_" })
    }

    private static func bullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "• ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func numbered(_ line: String) -> (String, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return ("\(digits).", String(rest.dropFirst(2)))
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
