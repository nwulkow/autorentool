import Foundation
import UIKit

/// Builds a minimal `.docx` (OOXML WordprocessingML) package from a
/// chapter's HTML `content` — the Swift replacement for app.js's
/// `htmlToDocxParagraphs`/`nodeToRuns` (app.js:1806-1860), which used the
/// `docx` JS library. There is no first-party Apple API that *writes*
/// `.docx` (only reads, see `DocxImporter`), so this hand-rolls the same
/// minimal OOXML app.js produced: a `word/document.xml` part naming
/// paragraphs/runs, wrapped in a ZIP by `ZipWriter`.
///
/// Rather than re-parsing the HTML with a second, fragile parser, this
/// reuses `HTMLConversion.attributedString` — the same `NSAttributedString
/// (.html)` path already trusted to round-trip Quill's output for on-screen
/// editing — and walks its paragraphs/runs, inferring heading level and
/// list/blockquote formatting from font size and paragraph indentation the
/// way `nodeToRuns` inferred it from tag names.
enum DocxExporter {
    /// Builds a single-chapter `.docx`, titled the same way app.js's
    /// `exportChapterDocx` titled it: always number-prefixed, preferring
    /// `name` over `label` (app.js:1785) — deliberately not the "prefer
    /// name, fall back to label, no number" convention the list/editor
    /// titles use elsewhere in this app, since this ports that specific
    /// export behavior.
    static func exportChapter(_ chapter: Chapter, index: Int) -> Data {
        let title = chapterTitle(chapter, index: index)
        let attributed = HTMLConversion.attributedString(fromHTML: chapter.content)
        let body = documentBody(title: title, content: attributed)
        return package(bodyXML: body)
    }

    /// Builds a multi-section `.docx` — one chapter after another — the
    /// same shape as app.js's `exportFullTextDocx` (app.js:1795-1805),
    /// which gave each chapter its own `docx` "section" but they still
    /// concatenate into a single document body when serialized.
    static func exportFullText(chapters: [Chapter]) -> Data {
        var body = ""
        for (index, chapter) in chapters.enumerated() {
            let title = chapterTitle(chapter, index: index)
            let attributed = HTMLConversion.attributedString(fromHTML: chapter.content)
            body += documentBody(title: title, content: attributed)
        }
        return package(bodyXML: body)
    }

    static func chapterTitle(_ chapter: Chapter, index: Int) -> String {
        let name = chapter.name.isEmpty ? chapter.label : chapter.name
        return "\(index + 1). \(name)"
    }

    static func filename(forChapter chapter: Chapter) -> String {
        let base = chapter.label.isEmpty ? "chapter" : chapter.label
        return sanitizedFilename(base) + ".docx"
    }

    static func filename(forBook title: String) -> String {
        sanitizedFilename(title.isEmpty ? "book" : title) + ".docx"
    }

    private static func sanitizedFilename(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        return String(raw.unicodeScalars.map { allowed.contains($0) ? Swift.Character($0) : "_" })
    }

    // MARK: - WordprocessingML body

    private static func documentBody(title: String, content: NSAttributedString) -> String {
        var xml = paragraph(runs: [(text: title, bold: true, italic: false, underline: false, strike: false)], headingLevel: 0, titleSize: true)
        xml += paragraphs(from: content)
        return xml
    }

    /// Walks the attributed string paragraph-by-paragraph (split on
    /// `\n`), emitting one `<w:p>` per paragraph and one `<w:r>` per run of
    /// consistent formatting within it — the OOXML equivalent of
    /// `nodeToRuns`' bold/italic/underline/strike walk, driven by
    /// `UIFont`/`NSParagraphStyle` attributes instead of DOM tag names.
    private static func paragraphs(from attributed: NSAttributedString) -> String {
        guard attributed.length > 0 else {
            return paragraph(runs: [], headingLevel: 0, titleSize: false)
        }
        var xml = ""
        let fullText = attributed.string as NSString
        var lineStart = 0
        while lineStart <= fullText.length {
            let remaining = NSRange(location: lineStart, length: fullText.length - lineStart)
            let lineRange = fullText.range(of: "\n", range: remaining)
            let paraRange: NSRange = lineRange.location == NSNotFound
                ? NSRange(location: lineStart, length: fullText.length - lineStart)
                : NSRange(location: lineStart, length: lineRange.location - lineStart)

            if paraRange.length > 0 {
                let paraText = attributed.attributedSubstring(from: paraRange)
                xml += paragraph(runs: runs(in: paraText), headingLevel: headingLevel(of: paraText), titleSize: false, indented: isIndented(paraText))
            }

            if lineRange.location == NSNotFound { break }
            lineStart = lineRange.location + 1
        }
        if xml.isEmpty {
            xml = paragraph(runs: [], headingLevel: 0, titleSize: false)
        }
        return xml
    }

    /// A paragraph can carry heading-sized text from two different
    /// origins that use different point sizes for the same semantic
    /// level: `HTMLConversion.attributedString`'s system HTML importer
    /// (confirmed in the Simulator: `<h1>`/`<h2>`/`<h3>` → 24/18/14pt) and
    /// `RichTextController.HeadingLevel`, applied when the user picks a
    /// heading from the in-editor toolbar (28/22/18pt). Both need to map
    /// to the same three OOXML heading styles, and the ranges below are
    /// wide enough to catch either source's H1/H2, but H1-HTML (24pt) and
    /// H3-toolbar (18pt) both sit close to H2's two candidate values
    /// (22/18pt) — ambiguous by point size alone, so this also requires
    /// bold, which every heading source sets but body text at these
    /// in-between sizes generally wouldn't.
    private static func headingLevel(of paragraph: NSAttributedString) -> Int {
        guard paragraph.length > 0, let font = paragraph.attribute(.font, at: 0, effectiveRange: nil) as? UIFont else { return 0 }
        let bold = font.fontDescriptor.symbolicTraits.contains(.traitBold)
        switch font.pointSize {
        case 23...: return 1
        case 19..<23: return bold ? 2 : 0
        case 13..<19: return bold ? 3 : 0
        default: return 0
        }
    }

    private static func isIndented(_ paragraph: NSAttributedString) -> Bool {
        guard paragraph.length > 0, let style = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle else { return false }
        return style.firstLineHeadIndent > 0 || style.headIndent > 0
    }

    private typealias RunFormat = (text: String, bold: Bool, italic: Bool, underline: Bool, strike: Bool)

    private static func runs(in paragraph: NSAttributedString) -> [RunFormat] {
        var result: [RunFormat] = []
        paragraph.enumerateAttributes(in: NSRange(location: 0, length: paragraph.length)) { attrs, range, _ in
            let text = (paragraph.string as NSString).substring(with: range)
            guard !text.isEmpty else { return }
            let font = attrs[.font] as? UIFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let underline = (attrs[.underlineStyle] as? Int ?? 0) != 0
            let strike = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
            result.append((text: text, bold: traits.contains(.traitBold), italic: traits.contains(.traitItalic), underline: underline, strike: strike))
        }
        return result
    }

    private static func paragraph(runs: [RunFormat], headingLevel: Int, titleSize: Bool, indented: Bool = false) -> String {
        var pPr = ""
        if titleSize {
            pPr += "<w:spacing w:after=\"200\"/>"
        } else if headingLevel > 0 {
            pPr += "<w:pStyle w:val=\"Heading\(headingLevel)\"/>"
        } else if indented {
            pPr += "<w:ind w:left=\"720\"/>"
        }
        let pPrXML = pPr.isEmpty ? "" : "<w:pPr>\(pPr)</w:pPr>"

        var runsXML = ""
        for run in runs {
            var rPr = ""
            if titleSize || run.bold { rPr += "<w:b/>" }
            if run.italic { rPr += "<w:i/>" }
            if run.underline { rPr += "<w:u w:val=\"single\"/>" }
            if run.strike { rPr += "<w:strike/>" }
            if titleSize { rPr += "<w:sz w:val=\"32\"/>" }
            let rPrXML = rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>"
            runsXML += "<w:r>\(rPrXML)<w:t xml:space=\"preserve\">\(escape(run.text))</w:t></w:r>"
        }
        return "<w:p>\(pPrXML)\(runsXML)</w:p>"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - OOXML package (ZIP of fixed parts + the generated body)

    private static func package(bodyXML: String) -> Data {
        var zip = ZipWriter()
        zip.addFile(path: "[Content_Types].xml", data: Data(contentTypesXML.utf8))
        zip.addFile(path: "_rels/.rels", data: Data(relsXML.utf8))
        zip.addFile(path: "word/_rels/document.xml.rels", data: Data(documentRelsXML.utf8))
        zip.addFile(path: "word/document.xml", data: Data(documentXML(body: bodyXML).utf8))
        zip.addFile(path: "word/styles.xml", data: Data(stylesXML.utf8))
        return zip.finalize()
    }

    private static func documentXML(body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>\(body)<w:sectPr/></w:body>
        </w:document>
        """
    }

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
    </Types>
    """

    private static let relsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    private static let documentRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    </Relationships>
    """

    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:docDefaults>
    <w:rPrDefault><w:rPr><w:sz w:val="22"/></w:rPr></w:rPrDefault>
    </w:docDefaults>
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:rPr><w:b/><w:sz w:val="28"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:rPr><w:b/><w:sz w:val="24"/></w:rPr></w:style>
    </w:styles>
    """
}
