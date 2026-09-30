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
        guard let attributed = try? NSAttributedString(data: inlinedAlignment(html) ?? data, options: options, documentAttributes: nil) else {
            return NSAttributedString(string: html, attributes: [.font: EditorTypography.body])
        }
        return normalized(attributed)
    }

    /// Rewrites Quill's alignment *classes* into the inline `text-align`
    /// the system importer actually honors.
    ///
    /// Same root cause as `normalized`'s font remapping: Quill stores
    /// alignment as `class="ql-align-justify"` (app.js), and the importer has
    /// no stylesheet to resolve that against, so every aligned paragraph
    /// arrived as `.natural` and was written back as a plain `<p>` — silently
    /// dropping the alignment on the first save from the phone. One book here
    /// has 102 justified paragraphs, so this is real prose formatting, not a
    /// cosmetic detail.
    private static func inlinedAlignment(_ html: String) -> Data? {
        var result = html
        for name in ["justify", "center", "right", "left"] {
            for quote in ["\"", "'"] {
                result = result.replacingOccurrences(
                    of: "class=\(quote)ql-align-\(name)\(quote)",
                    with: "style=\(quote)text-align: \(name);\(quote)"
                )
            }
        }
        return result == html ? nil : result.data(using: .utf8)
    }

    /// Writes the Quill-shaped fragment the web app expects: a flat run of
    /// `<p>`/`<h1-3>`/`<blockquote>` blocks carrying only inline `<strong>`,
    /// `<em>`, `<u>`, `<s>` and a `color:` span.
    ///
    /// The system writer (`NSAttributedString.data(from:documentAttributes:)`
    /// with `.html`) is deliberately *not* used here. It emits a complete
    /// `Cocoa HTML Writer` document — `<!DOCTYPE>`, `<html>`, `<head>`, a
    /// generated `<style>` block of `p.p1`/`span.s1` rules, then `<body>`.
    /// Assigning that to Quill's `root.innerHTML` (app.js:1881) drops the
    /// head, leaves every paragraph matched against stylesheet classes that
    /// no longer exist, and — because the writer breaks its markup across
    /// lines and closes each paragraph with a trailing `<br>` — renders as
    /// text with a spurious line break every line or so. That's exactly the
    /// "strangely formatted" chapter text seen in the web editor after
    /// writing on the phone.
    static func html(from attributed: NSAttributedString) -> String {
        guard attributed.length > 0 else { return "" }
        var blocks: [String] = []

        // Walk paragraph by paragraph: each newline-delimited run becomes one
        // block element, which is how Quill models a document (and why a
        // trailing `<br>` per paragraph is wrong).
        let text = attributed.string as NSString
        // Split on U+000A only. The importer uses *two* different line
        // characters and the distinction is the whole ballgame: `<br>` comes
        // back as U+2028 (LINE SEPARATOR) — a soft break *within* a
        // paragraph — while U+000A ends the paragraph. `<p>A<br>B</p>`
        // imports as "A\u{2028}B\u{000A}", and `<p><br></p>` as
        // "\u{2028}\u{000A}": one paragraph whose only content is a soft
        // break. Treating U+2028 as a boundary too (which is what
        // `lineRange(for:)` and `CharacterSet.newlines` both do) split every
        // blank line into two blocks and wrote two `<p><br></p>` back — so a
        // blank line doubled on every save, then doubled again.
        var start = 0
        var index = 0
        while index < text.length {
            let scalar = text.substring(with: NSRange(location: index, length: 1)).unicodeScalars.first
            if scalar == "\n" {
                blocks.append(block(from: attributed, range: NSRange(location: start, length: index - start)))
                start = index + 1
            }
            index += 1
        }
        // A document that doesn't end in U+000A has one last paragraph the
        // loop never closed. (One that does end in U+000A is already
        // complete — appending here would add the phantom trailing blank
        // line that used to accumulate one per save.)
        if start < text.length {
            blocks.append(block(from: attributed, range: NSRange(location: start, length: text.length - start)))
        }

        return blocks.joined()
    }

    /// One paragraph → one block element, with its inline runs inside.
    private static func block(from attributed: NSAttributedString, range: NSRange) -> String {
        guard range.length > 0 else { return "<p><br></p>" } // Quill's empty line

        var inner = ""
        attributed.enumerateAttributes(in: range) { attrs, runRange, _ in
            inner += inlineRun(attributed.attributedSubstring(from: runRange).string, attributes: attrs)
        }
        if inner.isEmpty { return "<p><br></p>" }

        let font = attributed.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont
        let paragraph = attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle

        // Blockquote is carried as head indent, matching how the importer
        // renders Quill's `<blockquote>` and how `DocxExporter` detects it.
        if let paragraph, paragraph.headIndent > 0 || paragraph.firstLineHeadIndent > 0 {
            return "<blockquote>\(inner)</blockquote>"
        }
        if let font, let level = headingLevel(forPointSize: font.pointSize) {
            // The importer marks headings bold, so `inlineRun` would wrap the
            // whole line in a redundant `<strong>` inside the `<h1>`. Drop it:
            // the heading tag already carries the weight, and leaving it in
            // churns the markup every time a chapter moves between apps.
            if inner.hasPrefix("<strong>"), inner.hasSuffix("</strong>"),
               !inner.dropFirst(8).dropLast(9).contains("<strong>") {
                inner = String(inner.dropFirst(8).dropLast(9))
            }
            return "<h\(level)>\(inner)</h\(level)>"
        }

        var attributes = ""
        if let paragraph {
            switch paragraph.alignment {
            case .center: attributes = " class=\"ql-align-center\""
            case .right: attributes = " class=\"ql-align-right\""
            case .justified: attributes = " class=\"ql-align-justify\""
            default: break
            }
        }
        return "<p\(attributes)>\(inner)</p>"
    }

    /// The inverse of `normalizedSize`: the heading scale this app writes
    /// (28/22/18, see `EditorTypography`) mapped back to `<h1>`/`<h2>`/`<h3>`
    /// so a heading survives the round trip as a heading rather than as body
    /// text that merely happens to be large.
    private static func headingLevel(forPointSize size: CGFloat) -> Int? {
        switch size {
        case 28...: return 1
        case 22..<28: return 2
        case 18.5..<22: return 3
        default: return nil
        }
    }

    private static func inlineRun(_ string: String, attributes: [NSAttributedString.Key: Any]) -> String {
        guard !string.isEmpty else { return "" }
        var html = escape(string)
        // U+2028 is how the importer represents `<br>`; write it back as one
        // rather than letting a raw separator into the file.
        html = html.replacingOccurrences(of: "\u{2028}", with: "<br>")
        let traits = (attributes[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
        if traits.contains(.traitBold) { html = "<strong>\(html)</strong>" }
        if traits.contains(.traitItalic) { html = "<em>\(html)</em>" }
        if let underline = attributes[.underlineStyle] as? Int, underline != 0 { html = "<u>\(html)</u>" }
        if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { html = "<s>\(html)</s>" }
        // Quill writes its color spans as `rgb(r, g, b)` (see the
        // `<span style="color: rgb(0, 0, 0);">` runs in existing chapter
        // JSON), so match that spelling rather than emitting hex — it keeps
        // a chapter's markup stable when it's edited alternately on both
        // apps instead of churning the diff on every save.
        if let color = attributes[.foregroundColor] as? UIColor, !isPlainBlack(color) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
                let ri = Int((r * 255).rounded()), gi = Int((g * 255).rounded()), bi = Int((b * 255).rounded())
                html = "<span style=\"color: rgb(\(ri), \(gi), \(bi));\">\(html)</span>"
            }
        }
        return html
    }

    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            // Written as an entity rather than a raw U+00A0 byte: that's how
            // Quill spells it, and a literal NBSP is invisible in a diff and
            // easy to mangle when the file is hand-edited.
            .replacingOccurrences(of: "\u{00a0}", with: "&nbsp;")
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
