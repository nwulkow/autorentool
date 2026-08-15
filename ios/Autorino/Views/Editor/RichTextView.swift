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
                let font = UIFont(descriptor: descriptor, size: level.pointSize)
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

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.attributedText = attributedText
        textView.isScrollEnabled = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.alwaysBounceVertical = true
        controller.textView = textView
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.attributedText != attributedText, !context.coordinator.isEditingInternally {
            let selected = uiView.selectedRange
            uiView.attributedText = attributedText
            uiView.selectedRange = selected
        }
        controller.textView = uiView
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichTextView
        var isEditingInternally = false

        init(_ parent: RichTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            isEditingInternally = true
            parent.attributedText = textView.attributedText
            isEditingInternally = false
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.selectedRange = textView.selectedRange
        }
    }
}
