import UIKit

/// Spell checking for the chapter editor.
///
/// app.js sets `lang="de-DE"`/`"en-US"` on the Quill root and lets the
/// *browser* check spelling (`applySpellcheckSettings`, app.js:1734-1741).
/// iOS has no equivalent: `UITextView`'s automatic red-squiggle pass follows
/// whichever keyboard is active and exposes no per-view language override,
/// which is why the ported DE/EN picker sat in the toolbar doing nothing.
///
/// `UITextChecker` *does* take an explicit language, so the check is run
/// here instead and the results are drawn by `SpellUnderlineOverlay`. Marks
/// are drawn, never stored as attributes: a `.underlineStyle` written into
/// the text storage would round-trip into the chapter's HTML through
/// `HTMLConversion` and show up as real underlines in the web app.
enum SpellCheck {
    /// Stored value meaning "don't check" — also what an unresolvable
    /// stored language falls back to.
    static let off = ""

    /// Only languages `UITextChecker` actually has a dictionary for on this
    /// device are ever offered, so every entry in the menu does something.
    /// Cached because `resolved(_:)` is read from `ChapterEditorView`'s body
    /// — i.e. on every keystroke — and the dictionary list doesn't change
    /// under a running app.
    private static let installed = UITextChecker.availableLanguages

    static var availableLanguages: [String] {
        installed.sorted { displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending }
    }

    static func displayName(for code: String) -> String {
        guard !code.isEmpty else { return String(localized: "Off") }
        let name = Locale.current.localizedString(forIdentifier: code) ?? code
        return name.prefix(1).localizedUppercase + name.dropFirst()
    }

    /// Maps a stored preference onto an available dictionary, so the legacy
    /// `"de"`/`"en"` values app.js's picker persisted keep working (they
    /// resolve to `de_DE`/`en_US`, or whatever regional variant this device
    /// ships) instead of silently checking nothing.
    static func resolved(_ stored: String) -> String? {
        guard !stored.isEmpty else { return nil }
        if installed.contains(stored) { return stored }
        let base = stored.replacingOccurrences(of: "-", with: "_").split(separator: "_").first.map(String.init) ?? stored
        return installed.first { $0 == base || $0.hasPrefix("\(base)_") }
    }

    /// The device's own writing language, when there's a dictionary for it.
    static var deviceDefault: String {
        for language in Locale.preferredLanguages {
            if let match = resolved(language) { return match }
        }
        return off
    }
}

/// Runs the checker over the part of the document the reader can actually
/// see and remembers what it found, so the overlay and the edit menu agree
/// on which words are flagged.
@MainActor
final class SpellCheckSession {
    /// Stored preference, resolved to a real dictionary (`nil` == off).
    var language: String?

    private let checker = UITextChecker()
    private(set) var ranges: [NSRange] = []

    /// Checking the whole manuscript on every keystroke would be wasted
    /// work — only what's on screen (plus a screen of slack either side, so
    /// a flick doesn't reveal unchecked text) can be seen anyway.
    private static let offscreenMargin: CGFloat = 400

    @discardableResult
    func recheck(_ textView: UITextView) -> [NSRange] {
        guard let language, !textView.text.isEmpty else {
            ranges = []
            return ranges
        }
        let text = textView.text as NSString
        var found: [NSRange] = []
        let searchRange = visibleCharacterRange(in: textView, textLength: text.length)
        var cursor = searchRange.location
        let end = NSMaxRange(searchRange)
        while cursor < end {
            let misspelled = checker.rangeOfMisspelledWord(
                in: text as String,
                range: NSRange(location: cursor, length: end - cursor),
                startingAt: cursor,
                wrap: false,
                language: language
            )
            guard misspelled.location != NSNotFound, misspelled.length > 0 else { break }
            found.append(misspelled)
            cursor = NSMaxRange(misspelled)
        }
        ranges = found
        return found
    }

    func range(intersecting range: NSRange) -> NSRange? {
        ranges.first { NSIntersectionRange($0, range).length > 0 || $0.location == range.location }
    }

    func guesses(for range: NSRange, in text: String) -> [String] {
        guard let language else { return [] }
        return checker.guesses(forWordRange: range, in: text, language: language) ?? []
    }

    func learn(word: String) {
        UITextChecker.learnWord(word)
    }

    func ignore(word: String) {
        checker.ignoreWord(word)
    }

    /// Character range covering the visible rect grown by `offscreenMargin`
    /// top and bottom. Uses TextKit 1 geometry — `EditorTextView` builds its
    /// stack around an explicit `NSLayoutManager` for exactly this and the
    /// overlay's rect enumeration.
    private func visibleCharacterRange(in textView: UITextView, textLength: Int) -> NSRange {
        let container = textView.textContainer
        let rect = CGRect(
            x: 0,
            y: max(0, textView.contentOffset.y - textView.textContainerInset.top - Self.offscreenMargin),
            width: max(container.size.width, 1),
            height: textView.bounds.height + Self.offscreenMargin * 2
        )
        let glyphRange = textView.layoutManager.glyphRange(forBoundingRect: rect, in: container)
        let charRange = textView.layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard charRange.length > 0 else { return NSRange(location: 0, length: min(textLength, 2000)) }
        // Grow to whole words so a word straddling the top edge isn't
        // reported misspelled just because it was cut in half.
        let start = max(0, charRange.location - 40)
        let length = min(textLength - start, charRange.length + 80)
        return NSRange(location: start, length: max(0, length))
    }
}

/// Draws the red dotted marks. A transparent, non-interactive sibling of the
/// text — pinned to the text view's *content*, so it scrolls with it — which
/// keeps the marks out of the text storage entirely.
final class SpellUnderlineOverlay: UIView {
    weak var textView: UITextView?

    var ranges: [NSRange] = [] {
        didSet {
            guard ranges != oldValue else { return }
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let textView, !ranges.isEmpty, let context = UIGraphicsGetCurrentContext() else { return }
        let layoutManager = textView.layoutManager
        let container = textView.textContainer
        let inset = textView.textContainerInset
        let textLength = (textView.text as NSString).length

        context.setStrokeColor(UIColor.systemRed.cgColor)
        context.setLineWidth(2)
        context.setLineCap(.round)
        context.setLineDash(phase: 0, lengths: [2, 3])

        for range in ranges where NSMaxRange(range) <= textLength {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { fragment, _ in
                let y = fragment.maxY + inset.top - 2
                context.move(to: CGPoint(x: fragment.minX + inset.left, y: y))
                context.addLine(to: CGPoint(x: fragment.maxX + inset.left, y: y))
                context.strokePath()
            }
        }
    }
}
