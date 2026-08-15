import Foundation

/// Swift replacement for app.js's `handleFileImport` (app.js:1871-1900).
///
/// `.docx` import is **not** free on iOS — `NSAttributedString`'s
/// `.docFormat`/`.officeOpenXML` document types are AppKit-only (macOS),
/// with no iOS availability at all (checked against the SDK headers; the
/// migration doc's original assumption that this "likely needs no Swift
/// equivalent" was wrong). So `.docx` is read the same way it's written:
/// unzip `word/document.xml` (`ZipReader`, deflate via the first-party
/// `Compression` framework) and walk it (`OOXMLDocumentParser`) — the same
/// paragraph/run subset `DocxExporter` produces, not a general Word
/// document reader (tables, images, footnotes aren't handled).
///
/// `.doc` (the legacy pre-2007 binary format) has no feasible reader here
/// either way — that's a proprietary binary format, not XML-in-a-zip — so
/// it's rejected with a clear error rather than silently mishandled.
enum DocxImporter {
    enum ImportError: Error { case unsupportedType, legacyDocUnsupported, readFailed }

    /// Reads a file at `url` and returns HTML content plus the chapter
    /// label app.js would have used (the filename, extension stripped —
    /// app.js:1889), ready to hand straight to `Chapter(content:)`.
    static func importChapter(from url: URL) throws -> (label: String, html: String) {
        let label = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()

        let needsSecurityScope = url.startAccessingSecurityScopedResource()
        defer { if needsSecurityScope { url.stopAccessingSecurityScopedResource() } }

        switch ext {
        case "txt":
            let text = try String(contentsOf: url, encoding: .utf8)
            let html = text
                .components(separatedBy: "\n")
                .map { line in "<p>\(line.isEmpty ? "<br>" : escape(line))</p>" }
                .joined()
            return (label, html)

        case "docx":
            let archive = try Data(contentsOf: url)
            guard let documentXML = try? ZipReader.extract(path: "word/document.xml", from: archive) else {
                throw ImportError.readFailed
            }
            let html = OOXMLDocumentParser.html(from: documentXML)
            return (label, html)

        case "doc":
            throw ImportError.legacyDocUnsupported

        default:
            throw ImportError.unsupportedType
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
