import UIKit

/// The manuscript type scale. Everything that writes a font into a chapter's
/// attributed string goes through here, so the three places that care about
/// point sizes agree on what "body" and "H1/H2/H3" mean: the editor toolbar
/// (`RichTextController.HeadingLevel`), the HTML importer's normalization
/// pass (`HTMLConversion.normalized`), and the heading inference
/// `DocxExporter.headingLevel(of:)` runs on the way back out to Word.
enum EditorTypography {
    /// Georgia is the member of `Theme.serif`'s Palatino/Book Antiqua/Georgia
    /// stack (styles.css:87) guaranteed to ship on iOS, and it carries real
    /// bold/italic/bold-italic faces so `withTraits` never has to fake a
    /// slant. Using it for chapter bodies — not just headings and chrome —
    /// is what makes the editor read as a manuscript page.
    static let familyName = "Georgia"

    /// Fixed, not `preferredFont(forTextStyle: .body).pointSize`: these
    /// numbers are persisted into chapter HTML and read back by
    /// `DocxExporter`, so they can't drift with the reader's Dynamic Type
    /// setting. On-screen size is a separate, display-only zoom
    /// (`RichTextView.scaled(_:)`).
    static let bodyPointSize: CGFloat = 17

    static func font(pointSize: CGFloat, traits: UIFontDescriptor.SymbolicTraits = []) -> UIFont {
        let base = UIFontDescriptor(fontAttributes: [.family: familyName])
        let descriptor = traits.isEmpty ? base : (base.withSymbolicTraits(traits) ?? base)
        return UIFont(descriptor: descriptor, size: pointSize)
    }

    static var body: UIFont { font(pointSize: bodyPointSize) }

    /// Warm ink matching `Theme.ink`.
    ///
    /// `UITextView.textColor` does *not* reach the runs of an attributed
    /// string — runs without an explicit `.foregroundColor` render plain
    /// black, which on the dark paper ground is all but invisible. So the
    /// ink is attached per run, but only in `RichTextView`'s display copy
    /// and stripped again by `modelText(_:)`: a color baked into the model
    /// would be exported as whichever interface style happened to be active,
    /// putting near-white text into a `books/*.json` the light-only web app
    /// also reads. Keeping it dynamic (rather than resolved) means the page
    /// follows a light/dark switch while it's open.
    static let inkColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.945, green: 0.918, blue: 0.867, alpha: 1)   // 0xF1EADD
            : UIColor(red: 0.173, green: 0.153, blue: 0.125, alpha: 1)   // 0x2C2720
    }

    private static let resolvedInk = [UIUserInterfaceStyle.light, .dark].map {
        inkColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: $0))
    }

    /// Whether a run's color is one this app applied for display, and so
    /// should come back off before the text is turned into HTML. Identity
    /// covers the dynamic instance handed out above; the resolved forms
    /// cover a copy that lost its dynamism on the way through.
    static func isInk(_ color: UIColor) -> Bool {
        color === inkColor || resolvedInk.contains { $0.isEqual(color) }
    }

    static let accentColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.439, green: 0.596, blue: 1.0, alpha: 1)     // 0x7098FF
            : UIColor(red: 0.290, green: 0.490, blue: 1.0, alpha: 1)     // 0x4A7DFF
    }
}

extension UIFont {
    func withTrait(_ trait: UIFontDescriptor.SymbolicTraits, on: Bool) -> UIFont {
        var traits = fontDescriptor.symbolicTraits
        if on { traits.insert(trait) } else { traits.remove(trait) }
        let descriptor = fontDescriptor.withSymbolicTraits(traits) ?? fontDescriptor
        return UIFont(descriptor: descriptor, size: pointSize)
    }

    var isBold: Bool { fontDescriptor.symbolicTraits.contains(.traitBold) }
    var isItalic: Bool { fontDescriptor.symbolicTraits.contains(.traitItalic) }
}

/// The zoom ladder behind the editor's −/+ control. Every step is a factor
/// with an exact binary representation (0.75, 1, 1.25, …), which matters
/// more than it looks: zoom is applied by multiplying every run's point size
/// on the way to the screen and dividing it back out on the way to the model
/// (`RichTextView.scaled(_:)`/`modelText(_:)`), so a step like app.js's ±10%
/// would leave 17.000000000000004pt behind in the saved HTML and eventually
/// slide a heading out of `DocxExporter`'s size buckets.
enum EditorZoom {
    static let steps = [75, 100, 125, 150, 175, 200, 250]

    /// 100% is now the size 150% used to render at.
    ///
    /// The old percentage was measured against the HTML importer's 12pt
    /// Times default (see `HTMLConversion.normalized`), so a Quill-authored
    /// chapter opened at 12pt and needed 150% to reach a readable 18pt. Body
    /// text now arrives at `EditorTypography.bodyPointSize` in Georgia,
    /// whose larger x-height makes 17pt read a shade *bigger* than that
    /// 18pt Times did — so the requested default size is 100% of the new
    /// scale, not 150% of it. `zoomBaseVersion` retires any percentage
    /// stored against the old baseline.
    static let `default` = 100

    /// Bumped when the meaning of a stored percentage changes, so
    /// `ChapterEditorView` knows to drop the old value once.
    static let baseVersion = 2

    static func snapped(_ value: Int) -> Int {
        steps.min { abs($0 - value) < abs($1 - value) } ?? `default`
    }

    static func next(after value: Int) -> Int {
        steps.first { $0 > value } ?? steps.last ?? value
    }

    static func previous(before value: Int) -> Int {
        steps.last { $0 < value } ?? steps.first ?? value
    }
}
