import Foundation
import UIKit

/// Converts between the chapter's on-disk HTML `content` (unchanged from
/// today's Quill output — see `docs/migration-architecture.md` §5) and the
/// `NSAttributedString` `UITextView` edits. Both directions run on the
/// main thread, as Apple's docs require for `.html` document type.
enum HTMLConversion {
    static func attributedString(fromHTML html: String) -> NSAttributedString {
        guard !html.isEmpty, let data = html.data(using: .utf8) else {
            return NSAttributedString(string: "", attributes: [.font: EditorTypography.body])
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return NSAttributedString(string: html, attributes: [.font: EditorTypography.body])
        }
        return normalized(attributed)
    }

    static func html(from attributed: NSAttributedString) -> String {
        guard attributed.length > 0 else { return "" }
        let range = NSRange(location: 0, length: attributed.length)
        let options: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: NSAttributedString.DocumentType.html]
        guard let data = try? attributed.data(from: range, documentAttributes: options),
              let html = String(data: data, encoding: .utf8) else { return "" }
        return html
    }

    // MARK: - Import normalization

    /// Quill writes its font and size choices as CSS *classes*
    /// (`ql-font-…`, `ql-size-…`, app.js:1589-1601), and the system HTML
    /// importer has no stylesheet to resolve them against — so a chapter
    /// written in the web app arrives here as Times New Roman 12pt, with
    /// `<h1>`/`<h2>`/`<h3>` at 24/18/14pt. That is neither the family this
    /// app writes nor the 28/22/18 heading scale `EditorTypography` and
    /// `DocxExporter` share, and 12pt is the real reason chapter text
    /// looked cramped and generic on screen.
    ///
    /// Only runs still wearing the importer's *default* face are remapped.
    /// A run that carries a real family — including HTML this app exported
    /// itself, which does name Georgia — is left exactly as it is, which is
    /// what keeps repeated save/load round trips idempotent rather than
    /// inflating sizes a little more each time.
    private static func normalized(_ attributed: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let full = NSRange(location: 0, length: mutable.length)

        mutable.enumerateAttribute(.font, in: full) { value, range, _ in
            guard let font = value as? UIFont else {
                mutable.addAttribute(.font, value: EditorTypography.body, range: range)
                return
            }
            guard isImporterDefault(font) else { return }
            mutable.addAttribute(
                .font,
                value: EditorTypography.font(pointSize: normalizedSize(font.pointSize), traits: font.fontDescriptor.symbolicTraits),
                range: range
            )
        }

        // The importer stamps plain black on unstyled text. Left in place
        // that survives into dark mode as black-on-espresso; dropped, the
        // run renders in the text view's own dynamic `textColor`
        // (`EditorTypography.inkColor`). Genuine Quill color choices are
        // anything but pure black, so they stay.
        mutable.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            guard let color = value as? UIColor, isPlainBlack(color) else { return }
            mutable.removeAttribute(.foregroundColor, range: range)
        }

        return mutable
    }

    private static func isImporterDefault(_ font: UIFont) -> Bool {
        font.familyName.hasPrefix("Times")
    }

    /// 12/24/18/14 are the importer's body/h1/h2/h3 sizes (confirmed in the
    /// Simulator, see `DocxExporter.headingLevel(of:)`). Anything else is a
    /// real inline `font-size` from a paste, scaled by the same 17/12 ratio
    /// so its relative emphasis survives.
    private static func normalizedSize(_ size: CGFloat) -> CGFloat {
        switch size {
        case 24: return 28
        case 18: return 22
        case 14: return 18
        case 12: return EditorTypography.bodyPointSize
        default: return (size * EditorTypography.bodyPointSize / 12).rounded()
        }
    }

    private static func isPlainBlack(_ color: UIColor) -> Bool {
        var white: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getWhite(&white, alpha: &alpha) else { return false }
        return white < 0.06 && alpha > 0.9
    }
}
