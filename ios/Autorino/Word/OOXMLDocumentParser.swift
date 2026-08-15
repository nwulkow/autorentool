import Foundation

/// Walks a WordprocessingML `word/document.xml` part and rebuilds it as
/// the same HTML shape `DocxExporter` writes paragraphs/runs *from* —
/// `<w:p>` → `<p>`/`<h1-3>`, `<w:r>` → a run of text carrying
/// bold/italic/underline/strike from `<w:rPr>`. This intentionally covers
/// only the same paragraph/run subset `DocxExporter` produces (see
/// `docs/migration-architecture.md` §5), not arbitrary Word documents —
/// tables, images, footnotes, and most styles fall back to plain text
/// rather than being dropped silently wrong.
enum OOXMLDocumentParser {
    static func html(from documentXML: Data) -> String {
        let delegate = Delegate()
        let parser = XMLParser(data: documentXML)
        parser.delegate = delegate
        parser.parse()
        return delegate.paragraphsHTML.joined()
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var paragraphsHTML: [String] = []

        private var inParagraph = false
        private var headingLevel = 0
        private var runs: [(text: String, bold: Bool, italic: Bool, underline: Bool, strike: Bool)] = []

        private var inRun = false
        private var runBold = false
        private var runItalic = false
        private var runUnderline = false
        private var runStrike = false
        private var runText = ""
        private var inText = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
            switch elementName {
            case "w:p":
                inParagraph = true
                headingLevel = 0
                runs = []
            case "w:pStyle":
                if let val = attributeDict["w:val"], let level = Self.headingLevel(fromStyleId: val) {
                    headingLevel = level
                }
            case "w:r":
                inRun = true
                runBold = false; runItalic = false; runUnderline = false; runStrike = false
                runText = ""
            case "w:b":
                if inRun { runBold = attributeDict["w:val"] != "false" && attributeDict["w:val"] != "0" }
            case "w:i":
                if inRun { runItalic = attributeDict["w:val"] != "false" && attributeDict["w:val"] != "0" }
            case "w:u":
                if inRun { runUnderline = attributeDict["w:val"] != "none" }
            case "w:strike":
                if inRun { runStrike = attributeDict["w:val"] != "false" && attributeDict["w:val"] != "0" }
            case "w:t":
                inText = true
            case "w:tab":
                if inRun { runText += "\t" }
            case "w:br":
                if inRun { runText += "\n" }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { runText += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            switch elementName {
            case "w:t":
                inText = false
            case "w:r":
                if !runText.isEmpty {
                    runs.append((text: runText, bold: runBold, italic: runItalic, underline: runUnderline, strike: runStrike))
                }
                inRun = false
            case "w:p":
                paragraphsHTML.append(Self.paragraphHTML(runs: runs, headingLevel: headingLevel))
                inParagraph = false
            default:
                break
            }
        }

        private static func headingLevel(fromStyleId styleId: String) -> Int? {
            switch styleId {
            case "Heading1", "heading1", "Heading 1": return 1
            case "Heading2", "heading2", "Heading 2": return 2
            case "Heading3", "heading3", "Heading 3": return 3
            default: return nil
            }
        }

        private static func paragraphHTML(runs: [(text: String, bold: Bool, italic: Bool, underline: Bool, strike: Bool)], headingLevel: Int) -> String {
            let inner = runs.map { run -> String in
                var text = escape(run.text)
                if run.strike { text = "<s>\(text)</s>" }
                if run.underline { text = "<u>\(text)</u>" }
                if run.italic { text = "<em>\(text)</em>" }
                if run.bold { text = "<strong>\(text)</strong>" }
                return text
            }.joined()

            switch headingLevel {
            case 1: return "<h1>\(inner)</h1>"
            case 2: return "<h2>\(inner)</h2>"
            case 3: return "<h3>\(inner)</h3>"
            default: return "<p>\(inner.isEmpty ? "<br>" : inner)</p>"
            }
        }

        private static func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\n", with: "<br>")
        }
    }
}
