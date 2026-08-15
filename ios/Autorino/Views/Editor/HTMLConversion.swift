import Foundation
import UIKit

/// Converts between the chapter's on-disk HTML `content` (unchanged from
/// today's Quill output — see `docs/migration-architecture.md` §5) and the
/// `NSAttributedString` `UITextView` edits. Both directions run on the
/// main thread, as Apple's docs require for `.html` document type.
enum HTMLConversion {
    static func attributedString(fromHTML html: String) -> NSAttributedString {
        guard !html.isEmpty, let data = html.data(using: .utf8) else {
            return NSAttributedString(string: "", attributes: [.font: UIFont.preferredFont(forTextStyle: .body)])
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return NSAttributedString(string: html)
        }
        return attributed
    }

    static func html(from attributed: NSAttributedString) -> String {
        guard attributed.length > 0 else { return "" }
        let range = NSRange(location: 0, length: attributed.length)
        let options: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: NSAttributedString.DocumentType.html]
        guard let data = try? attributed.data(from: range, documentAttributes: options),
              let html = String(data: data, encoding: .utf8) else { return "" }
        return html
    }
}
