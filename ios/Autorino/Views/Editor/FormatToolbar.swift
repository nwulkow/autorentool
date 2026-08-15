import SwiftUI

/// Compact formatting bar above the text view — the subset of Quill's
/// toolbar (app.js:1490-1502) that matters most for phone-width editing:
/// bold/italic/underline plus heading sizes. Color/font-family/lists are
/// deferred along with the rest of the richer editor chrome.
struct FormatToolbar: View {
    @ObservedObject var controller: RichTextController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Button { controller.toggleBold() } label: { Image(systemName: "bold") }
                Button { controller.toggleItalic() } label: { Image(systemName: "italic") }
                Button { controller.toggleUnderline() } label: { Image(systemName: "underline") }
                Divider().frame(height: 20)
                ForEach(RichTextController.HeadingLevel.allCases, id: \.self) { level in
                    Button(level.label) { controller.setHeading(level) }
                        .font(.footnote)
                }
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}
