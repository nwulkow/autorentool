import SwiftUI
import UIKit

/// Drives formatting commands from `FormatToolbar` into whichever
/// `UITextView` is currently on screen. Replaces Quill's toolbar API
/// (app.js:1490-1502) with direct `NSAttributedString` attribute edits —
/// same formatting surface (bold/italic/underline/heading sizes), no
/// framework underneath.
@MainActor
final class RichTextController: ObservableObject {
    fileprivate weak var textView: UITextView?
    /// Kept in sync by `RichTextView.updateUIView` so `setHeading`'s
    /// absolute point sizes land correctly relative to whatever zoom the
    /// on-screen (display-only, see `RichTextView.scaled(_:)`) text is
    /// currently rendered at — otherwise a heading set while zoomed would
    /// persist at the wrong size once `unscaled()` divides it back down.
    fileprivate var zoomScale: CGFloat = 1

    func toggleBold() { toggleSymbolicTrait(.traitBold) }
    func toggleItalic() { toggleSymbolicTrait(.traitItalic) }

    func toggleUnderline() {
        mutateSelection { mutable, range in
            let hasUnderline = mutable.attribute(.underlineStyle, at: range.location, effectiveRange: nil) != nil
            mutable.addAttribute(.underlineStyle, value: hasUnderline ? 0 : NSUnderlineStyle.single.rawValue, range: range)
        }
    }

    func setHeading(_ level: HeadingLevel) {
        mutateSelection { mutable, range in
            mutable.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let base = (value as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
                let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits) ?? base.fontDescriptor
                let font = UIFont(descriptor: descriptor, size: level.pointSize * self.zoomScale)
                mutable.addAttribute(.font, value: level.isHeading ? font.bold() : font, range: subrange)
            }
        }
    }

    enum HeadingLevel: CaseIterable {
        case body, h1, h2, h3

        var pointSize: CGFloat {
            switch self {
            case .body: return UIFont.preferredFont(forTextStyle: .body).pointSize
            case .h1: return 28
            case .h2: return 22
            case .h3: return 18
            }
        }
        var isHeading: Bool { self != .body }
        var label: String {
            switch self {
            case .body: return String(localized: "Body")
            case .h1: return "H1"
            case .h2: return "H2"
            case .h3: return "H3"
            }
        }
    }

    private func toggleSymbolicTrait(_ trait: UIFontDescriptor.SymbolicTraits) {
        mutateSelection { mutable, range in
            mutable.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let font = (value as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
                var traits = font.fontDescriptor.symbolicTraits
                if traits.contains(trait) { traits.remove(trait) } else { traits.insert(trait) }
                let descriptor = font.fontDescriptor.withSymbolicTraits(traits) ?? font.fontDescriptor
                mutable.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: subrange)
            }
        }
    }

    private func mutateSelection(_ body: (NSMutableAttributedString, NSRange) -> Void) {
        guard let textView, textView.selectedRange.length > 0 else { return }
        let selected = textView.selectedRange
        let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
        body(mutable, selected)
        textView.attributedText = mutable
        textView.selectedRange = selected
        // Setting `.attributedText` programmatically doesn't fire the
        // delegate on its own — tell it explicitly so the SwiftUI binding
        // (and autosave) picks up the toolbar-driven change.
        textView.delegate?.textViewDidChange?(textView)
    }
}

private extension UIFont {
    func bold() -> UIFont {
        let traits = fontDescriptor.symbolicTraits.union(.traitBold)
        let descriptor = fontDescriptor.withSymbolicTraits(traits) ?? fontDescriptor
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

/// `UIViewRepresentable` wrapper around `UITextView`, bound to an
/// `NSAttributedString` — the native replacement for Quill (see
/// `docs/migration-architecture.md` §5).
struct RichTextView: UIViewRepresentable {
    @Binding var attributedText: NSAttributedString
    @Binding var selectedRange: NSRange
    @ObservedObject var controller: RichTextController
    /// Display-only zoom; see `scaled(_:)` below for why `attributedText`
    /// itself never carries this scale.
    var zoomPercent: Int = 100
    /// Mirrors `applySpellcheckSettings` (app.js:1734-1741), which sets
    /// `lang="de-DE"`/`"en-US"` on the Quill root so the *browser's* spell
    /// checker switches language. Checked directly against the iOS SDK
    /// headers: `UITextView`/`UITextInputTraits` expose no per-view spell-
    /// check language override — the automatic red-squiggle pass always
    /// follows whichever keyboard the user has active, which the app
    /// cannot set. So this stays a persisted user preference (surfaced in
    /// `EditorChromeBar` for parity with app.js's picker) without a device
    /// effect beyond `spellCheckingType = .yes` below; if Apple ever adds
    /// a language override, this is the value it plugs into.
    var spellLanguage: String = "de"

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.attributedText = scaled(attributedText)
        textView.isScrollEnabled = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.alwaysBounceVertical = true
        textView.spellCheckingType = .yes
        controller.textView = textView
        controller.zoomScale = CGFloat(zoomPercent) / 100
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let needsModelSync = uiView.attributedText.string != scaled(attributedText).string && !context.coordinator.isEditingInternally
        let zoomChanged = context.coordinator.lastAppliedZoom != zoomPercent
        guard needsModelSync || zoomChanged else { return }
        context.coordinator.lastAppliedZoom = zoomPercent
        let selected = uiView.selectedRange
        uiView.attributedText = scaled(attributedText)
        uiView.selectedRange = selected
        controller.textView = uiView
        controller.zoomScale = CGFloat(zoomPercent) / 100
    }

    /// Mirrors `applyTeZoom` scaling the whole editor's `font-size`
    /// (app.js:1727-1732): a *display-only* transform, same as app.js's
    /// CSS `font-size` on the Quill root never touching the underlying
    /// Delta. `attributedText` (the model/binding, persisted as HTML via
    /// `HTMLConversion`) always stays at 100% — only the copy handed to
    /// `UITextView` is scaled; `Coordinator.textViewDidChange` scales back
    /// down before writing to the binding, so zoom never bakes into saved
    /// content.
    private func scaled(_ text: NSAttributedString) -> NSAttributedString {
        guard zoomPercent != 100 else { return text }
        let scale = CGFloat(zoomPercent) / 100
        let mutable = NSMutableAttributedString(attributedString: text)
        mutable.enumerateAttribute(.font, in: NSRange(location: 0, length: mutable.length)) { value, range, _ in
            let base = (value as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
            mutable.addAttribute(.font, value: base.withSize(base.pointSize * scale), range: range)
        }
        return mutable
    }

    private func unscaled(_ text: NSAttributedString) -> NSAttributedString {
        guard zoomPercent != 100 else { return text }
        let scale = CGFloat(zoomPercent) / 100
        let mutable = NSMutableAttributedString(attributedString: text)
        mutable.enumerateAttribute(.font, in: NSRange(location: 0, length: mutable.length)) { value, range, _ in
            let base = (value as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
            mutable.addAttribute(.font, value: base.withSize(base.pointSize / scale), range: range)
        }
        return mutable
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichTextView
        var isEditingInternally = false
        var lastAppliedZoom = 100

        init(_ parent: RichTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            isEditingInternally = true
            parent.attributedText = parent.unscaled(textView.attributedText)
            isEditingInternally = false
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.selectedRange = textView.selectedRange
        }
    }
}
