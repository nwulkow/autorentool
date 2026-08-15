import SwiftUI

/// The editor's single chrome row — the subset of Quill's toolbar
/// (app.js:1490-1502) that matters for phone-width writing: bold/italic/
/// underline, the paragraph style, and zoom.
///
/// This replaces the two stacked bars the port started with (this one plus
/// `EditorChromeBar`'s A4/A5 and DE/EN pickers). A4/A5 sized a page column
/// that a phone is never wide enough to show, and the DE/EN pair drove a
/// spell-check language iOS won't accept — both were chrome that couldn't
/// act. Page width is now automatic (`ChapterEditorView.page`) and spelling
/// moved to the chapter's overflow menu, where it can list the dictionaries
/// the device actually has.
struct FormatToolbar: View {
    @ObservedObject var controller: RichTextController
    @Binding var zoom: Int

    var body: some View {
        HStack(spacing: 6) {
            toggle("bold", isOn: controller.format.bold, label: String(localized: "Bold")) { controller.toggleBold() }
            toggle("italic", isOn: controller.format.italic, label: String(localized: "Italic")) { controller.toggleItalic() }
            toggle("underline", isOn: controller.format.underline, label: String(localized: "Underline")) { controller.toggleUnderline() }

            Divider().frame(height: 20).padding(.horizontal, 2)

            styleMenu

            Spacer(minLength: 0)

            zoomControl
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.chrome)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line), alignment: .bottom)
    }

    /// A menu rather than four buttons: it fits, and it *shows the current
    /// paragraph style*, so applying a heading has visible feedback even
    /// where the size change alone is subtle.
    private var styleMenu: some View {
        Menu {
            Picker("Paragraph style", selection: headingBinding) {
                ForEach(RichTextController.HeadingLevel.allCases) { level in
                    Label(level.label, systemImage: level.systemImage).tag(level)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(controller.format.heading.label)
                    .font(.footnote.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .accessibilityLabel(Text("Paragraph style"))
    }

    private var headingBinding: Binding<RichTextController.HeadingLevel> {
        Binding(
            get: { controller.format.heading },
            set: { controller.setHeading($0) }
        )
    }

    private var zoomControl: some View {
        HStack(spacing: 0) {
            stepButton("minus", enabled: zoom > (EditorZoom.steps.first ?? zoom)) {
                zoom = EditorZoom.previous(before: zoom)
            }
            Text("\(zoom)%")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.muted)
                .frame(width: 40)
            stepButton("plus", enabled: zoom < (EditorZoom.steps.last ?? zoom)) {
                zoom = EditorZoom.next(after: zoom)
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 30)
        .background(Theme.panel, in: Capsule())
        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
    }

    private func stepButton(_ systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.accent : Theme.muted.opacity(0.5))
        .disabled(!enabled)
    }

    private func toggle(_ systemImage: String, isOn: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 30)
                .foregroundStyle(isOn ? Color.white : Theme.ink)
                .background(isOn ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
