import SwiftUI
import UIKit

/// Drives formatting commands from `FormatToolbar` into whichever
/// `UITextView` is currently on screen, and publishes what the caret or
/// selection is currently wearing so the toolbar can show state. Replaces
/// Quill's toolbar API plus its `getFormat` (app.js:1490-1502) with direct
/// `NSAttributedString` attribute edits — same formatting surface
/// (bold/italic/underline/heading sizes), no framework underneath.
@MainActor
final class RichTextController: ObservableObject {

    /// What the toolbar renders as "on". Recomputed from the selection, or
    /// from the caret's typing attributes when there's nothing selected.
    struct FormatState: Equatable {
        var bold = false
        var italic = false
        var underline = false
        var heading: HeadingLevel = .body
    }

    enum HeadingLevel: CaseIterable, Identifiable {
        case body, h1, h2, h3

        var id: Self { self }

        /// Point sizes as *stored*, before zoom. `DocxExporter` infers Word
        /// heading styles from these exact numbers, so they're fixed rather
        /// than derived from Dynamic Type.
        var pointSize: CGFloat {
            switch self {
            case .body: return EditorTypography.bodyPointSize
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

        var systemImage: String {
            switch self {
            case .body: return "text.alignleft"
            case .h1: return "textformat.size.larger"
            case .h2: return "textformat.size"
            case .h3: return "textformat.size.smaller"
            }
        }

        /// Body and H3 sit 1pt apart, so bold is what separates them —
        /// every heading this app applies is bold, matching the rule
        /// `DocxExporter.headingLevel(of:)` already relies on.
        static func matching(pointSize: CGFloat, bold: Bool) -> HeadingLevel {
            guard bold else { return .body }
            switch pointSize {
            case 25...: return .h1
            case 20..<25: return .h2
            case 17.5..<20: return .h3
            default: return .body
            }
        }
    }

    @Published private(set) var format = FormatState()

    /// Mirrors the editor's `UndoManager` so the toolbar can dim its
    /// history buttons. Recomputed alongside `format` — every keystroke
    /// moves the caret, so the selection callback is already a reliable
    /// tick — plus the manager's own notifications, which is what catches
    /// shake-to-undo and the hardware ⌘Z.
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Presents the system find/replace bar (`UIFindInteraction`, iOS 16+)
    /// over the editor — the native counterpart of Quill's absent search,
    /// which app.js never had either. No hand-rolled search UI: the system
    /// bar already does match highlighting, next/previous, and replace.
    func presentFind() {
        textView?.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    fileprivate weak var textView: UITextView?
    /// Kept in sync by `RichTextView` so heading point sizes land correctly
    /// relative to whatever zoom the on-screen (display-only, see
    /// `RichTextView.scaled(_:)`) text is currently rendered at — otherwise
    /// a heading set while zoomed would persist at the wrong size once
    /// `modelText(_:)` divides it back down.
    fileprivate var zoomScale: CGFloat = 1
    private var refreshScheduled = false
    private var undoObservers: [NSObjectProtocol] = []

    // MARK: - History

    /// The editor's undo stack is `UITextView`'s own, so typing and
    /// deletions are already recorded — including the case this exists for,
    /// a paragraph selected and wiped. `UndoManager` keeps every step by
    /// default (`levelsOfUndo == 0`), so how far back you can go is bounded
    /// only by how long the chapter has been open.
    func undo() {
        guard let textView, let manager = textView.undoManager, manager.canUndo else { return }
        manager.undo()
        finishHistoryCommand(on: textView)
    }

    func redo() {
        guard let textView, let manager = textView.undoManager, manager.canRedo else { return }
        manager.redo()
        finishHistoryCommand(on: textView)
    }

    private func finishHistoryCommand(on textView: UITextView) {
        // UIKit's own text undo notifies the delegate, ours does too, but
        // saying so once more here costs a string compare and guarantees the
        // SwiftUI binding (and with it the autosave) sees the result.
        textView.delegate?.textViewDidChange?(textView)
        scheduleRefresh()
    }

    /// Attribute-only `textStorage` edits bypass `UITextView`'s undo
    /// registration entirely, so without this a bold or heading tap would be
    /// the one change undo couldn't take back. Snapshots are whole-document:
    /// cheap at chapter length, and immune to the range drift a finer-grained
    /// record would suffer once other edits land on top.
    private func registerHistoryStep(on textView: UITextView, restoring snapshot: NSAttributedString, selection: NSRange) {
        guard let manager = textView.undoManager else { return }
        manager.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                guard let target = controller.textView else { return }
                let inverse = NSAttributedString(attributedString: target.textStorage)
                controller.registerHistoryStep(on: target, restoring: inverse, selection: target.selectedRange)
                target.textStorage.setAttributedString(snapshot)
                target.selectedRange = Self.clamped(selection, to: target.textStorage.length)
                target.delegate?.textViewDidChange?(target)
                controller.scheduleRefresh()
            }
        }
        manager.setActionName(String(localized: "Formatting"))
    }

    private static func clamped(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        return NSRange(location: location, length: min(range.length, length - location))
    }

    // MARK: - Commands

    func toggleBold() { setTrait(.traitBold, on: !format.bold) }
    func toggleItalic() { setTrait(.traitItalic, on: !format.italic) }

    func toggleUnderline() {
        let on = !format.underline
        guard let textView else { return }
        let range = textView.selectedRange
        guard range.length > 0 else {
            var attributes = textView.typingAttributes
            attributes[.underlineStyle] = on ? NSUnderlineStyle.single.rawValue : 0
            textView.typingAttributes = attributes
            scheduleRefresh()
            return
        }
        edit(textView) { storage in
            if on {
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            } else {
                storage.removeAttribute(.underlineStyle, range: range)
            }
        }
    }

    /// A heading is a property of the whole paragraph, so with nothing
    /// selected this applies to the paragraph the caret sits in. The
    /// previous version required a selection and quietly did nothing
    /// otherwise, which is the whole reason Body/H1/H2/H3 looked inert.
    func setHeading(_ level: HeadingLevel) {
        guard let textView else { return }
        let string = textView.textStorage.string as NSString
        let caret = min(textView.selectedRange.location, string.length)
        let selection = NSRange(location: caret, length: min(textView.selectedRange.length, string.length - caret))
        let paragraph = string.length > 0 ? string.paragraphRange(for: selection) : NSRange(location: 0, length: 0)
        let size = level.pointSize * zoomScale

        guard paragraph.length > 0 else {
            // Empty document or empty last line: nothing to restyle, so aim
            // the change at what gets typed next.
            var attributes = textView.typingAttributes
            let current = (attributes[.font] as? UIFont) ?? EditorTypography.font(pointSize: size)
            attributes[.font] = headingFont(size: size, level: level, basedOn: current)
            textView.typingAttributes = attributes
            scheduleRefresh()
            return
        }

        edit(textView) { storage in
            storage.enumerateAttribute(.font, in: paragraph) { value, subrange, _ in
                let current = (value as? UIFont) ?? EditorTypography.font(pointSize: size)
                storage.addAttribute(.font, value: self.headingFont(size: size, level: level, basedOn: current), range: subrange)
            }
        }
        var attributes = textView.typingAttributes
        let current = (attributes[.font] as? UIFont) ?? EditorTypography.font(pointSize: size)
        attributes[.font] = headingFont(size: size, level: level, basedOn: current)
        textView.typingAttributes = attributes
    }

    private func headingFont(size: CGFloat, level: HeadingLevel, basedOn current: UIFont) -> UIFont {
        var traits = current.fontDescriptor.symbolicTraits
        // Headings are always bold; going back to Body has to clear it
        // again, or "Body" would leave a bold paragraph behind and read as
        // another no-op.
        if level.isHeading { traits.insert(.traitBold) } else { traits.remove(.traitBold) }
        return EditorTypography.font(pointSize: size, traits: traits)
    }

    /// Applies the trait uniformly across the selection based on the state
    /// the toolbar is showing, rather than flipping each run independently —
    /// a half-bold selection now goes fully bold on the first tap instead of
    /// inverting into the other half.
    private func setTrait(_ trait: UIFontDescriptor.SymbolicTraits, on: Bool) {
        guard let textView else { return }
        let range = textView.selectedRange
        guard range.length > 0 else {
            var attributes = textView.typingAttributes
            let font = (attributes[.font] as? UIFont) ?? scaledBodyFont
            attributes[.font] = font.withTrait(trait, on: on)
            textView.typingAttributes = attributes
            scheduleRefresh()
            return
        }
        edit(textView) { storage in
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let font = (value as? UIFont) ?? self.scaledBodyFont
                storage.addAttribute(.font, value: font.withTrait(trait, on: on), range: subrange)
            }
        }
    }

    private var scaledBodyFont: UIFont {
        EditorTypography.font(pointSize: EditorTypography.bodyPointSize * zoomScale)
    }

    /// Edits the text storage **in place** and restores the scroll position
    /// around it.
    ///
    /// The previous implementation assigned `textView.attributedText`, which
    /// throws away the layout and leaves the scroll view pinned to the end
    /// of the document — that's why bolding a word jumped the view to the
    /// bottom. Mutating `textStorage` between `beginEditing()`/`endEditing()`
    /// keeps the existing layout and only re-lays out what changed.
    private func edit(_ textView: UITextView, _ body: (NSTextStorage) -> Void) {
        let selection = textView.selectedRange
        let offset = textView.contentOffset
        let snapshot = NSAttributedString(attributedString: textView.textStorage)
        textView.textStorage.beginEditing()
        body(textView.textStorage)
        textView.textStorage.endEditing()
        textView.selectedRange = selection
        registerHistoryStep(on: textView, restoring: snapshot, selection: selection)
        if textView.contentOffset != offset {
            textView.setContentOffset(offset, animated: false)
        }
        // Attribute-only storage edits don't call the delegate on their own —
        // tell it explicitly so the SwiftUI binding (and autosave) picks up
        // the toolbar-driven change.
        textView.delegate?.textViewDidChange?(textView)
        scheduleRefresh()
    }

    // MARK: - Toolbar state

    /// Always hops to the next runloop turn: selection callbacks can fire
    /// while SwiftUI is mid-update (`updateUIView` restoring a selection),
    /// and publishing from inside that draws a runtime warning.
    fileprivate func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refreshNow()
        }
    }

    private func refreshNow() {
        guard let textView else { return }
        let range = textView.selectedRange
        let storage = textView.textStorage
        let attributes: [NSAttributedString.Key: Any]
        if range.length > 0, range.location < storage.length {
            attributes = storage.attributes(at: range.location, effectiveRange: nil)
        } else {
            attributes = textView.typingAttributes
        }
        let font = (attributes[.font] as? UIFont) ?? scaledBodyFont
        var next = FormatState()
        next.bold = font.isBold
        next.italic = font.isItalic
        next.underline = (attributes[.underlineStyle] as? Int ?? 0) != 0
        next.heading = HeadingLevel.matching(pointSize: font.pointSize / max(zoomScale, 0.01), bold: font.isBold)
        if next != format { format = next }

        let manager = textView.undoManager
        let undoable = manager?.canUndo ?? false
        let redoable = manager?.canRedo ?? false
        if canUndo != undoable { canUndo = undoable }
        if canRedo != redoable { canRedo = redoable }
    }

    // MARK: - Attachment

    /// Called on every `updateUIView`, so it has to be cheap and idempotent:
    /// only a genuinely different text view re-subscribes.
    fileprivate func attach(to textView: UITextView) {
        guard self.textView !== textView else { return }
        self.textView = textView
        observeUndoManager(textView.undoManager)
    }

    private func observeUndoManager(_ manager: UndoManager?) {
        undoObservers.forEach(NotificationCenter.default.removeObserver)
        undoObservers = []
        guard let manager else { return }
        let names: [Notification.Name] = [
            .NSUndoManagerDidCloseUndoGroup,
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange,
        ]
        undoObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: manager, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            }
        }
    }

    deinit {
        undoObservers.forEach(NotificationCenter.default.removeObserver)
    }
}

// MARK: - Text view

/// `UITextView` subclass that owns the spell-mark overlay and keeps it
/// covering the full scrollable content.
///
/// It builds its own TextKit 1 stack deliberately: both the overlay's rect
/// enumeration and `SpellCheckSession`'s visible-range math go through
/// `layoutManager`, and merely touching that property on a TextKit 2 view
/// drops it back to TextKit 1 anyway — better to ask for it outright than to
/// trip the compatibility path.
final class EditorTextView: UITextView {
    let spellOverlay = SpellUnderlineOverlay()

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        spellOverlay.textView = self
        addSubview(spellOverlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = CGSize(width: max(contentSize.width, bounds.width), height: max(contentSize.height, bounds.height))
        if spellOverlay.frame.size != size {
            spellOverlay.frame = CGRect(origin: .zero, size: size)
        }
        if spellOverlay.superview !== self {
            addSubview(spellOverlay)
        }
        bringSubviewToFront(spellOverlay)
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
    var zoomPercent: Int = EditorZoom.default
    /// Resolved `UITextChecker` language, or `nil` for off. See `SpellCheck`
    /// for why this can't be handed to `UITextInputTraits` instead.
    var spellLanguage: String?

    func makeUIView(context: Context) -> UITextView {
        let textView = EditorTextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textColor = EditorTypography.inkColor
        textView.tintColor = EditorTypography.accentColor
        textView.font = EditorTypography.body
        textView.typingAttributes = [
            .font: EditorTypography.font(pointSize: EditorTypography.bodyPointSize * CGFloat(zoomPercent) / 100),
            .foregroundColor: EditorTypography.inkColor,
        ]
        textView.attributedText = scaled(attributedText)
        textView.isScrollEnabled = true
        // Generous margins are most of what makes this read as a page
        // rather than a text field; the deep bottom inset means the last
        // paragraph can still be scrolled clear of the keyboard.
        textView.textContainerInset = UIEdgeInsets(top: 22, left: 18, bottom: 96, right: 18)
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        // The system pass follows the keyboard's language and can't be
        // pointed anywhere else, so `SpellCheckSession` does the checking
        // and `SpellUnderlineOverlay` draws it.
        textView.spellCheckingType = .no
        // Enables the system find bar (`RichTextController.presentFind()`)
        // and, as a side effect, the ⌘F keyboard shortcut on an external
        // keyboard/Catalyst trackpad setup.
        textView.isFindInteractionEnabled = true
        context.coordinator.textView = textView
        context.coordinator.lastAppliedZoom = zoomPercent
        controller.zoomScale = CGFloat(zoomPercent) / 100
        controller.attach(to: textView)
        controller.scheduleRefresh()
        context.coordinator.updateSpellLanguage(spellLanguage)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // Without this the coordinator keeps the *first* `RichTextView`
        // struct forever, so `modelText(_:)` would keep dividing by a stale
        // zoom after every change and bake the scale into saved content.
        context.coordinator.parent = self
        controller.zoomScale = CGFloat(zoomPercent) / 100
        controller.attach(to: uiView)

        let previousZoom = context.coordinator.lastAppliedZoom
        let needsModelSync = uiView.attributedText.string != attributedText.string && !context.coordinator.isEditingInternally
        let zoomChanged = previousZoom != zoomPercent

        if needsModelSync || zoomChanged {
            context.coordinator.lastAppliedZoom = zoomPercent
            let selected = uiView.selectedRange
            // Re-derive the on-screen text from the model rather than
            // rescaling what's already there: exact sizes every time, no
            // rounding residue accumulating in the saved HTML.
            let ratio = uiView.contentSize.height > 0 ? uiView.contentOffset.y / uiView.contentSize.height : 0
            uiView.attributedText = scaled(attributedText)
            // Replacing the storage invalidates every recorded step: UIKit's
            // own entries point at ranges in text that no longer exists, and
            // a formatting snapshot taken at the previous zoom would be
            // divided by the new one and bake the wrong point sizes into the
            // saved HTML. Cheaper to start the history over than to restore
            // something wrong.
            uiView.undoManager?.removeAllActions()
            if selected.location <= uiView.textStorage.length {
                uiView.selectedRange = NSRange(location: selected.location, length: min(selected.length, uiView.textStorage.length - selected.location))
            }
            if zoomChanged {
                if let font = uiView.typingAttributes[.font] as? UIFont {
                    uiView.typingAttributes[.font] = font.withSize(font.pointSize / CGFloat(max(previousZoom, 1)) * CGFloat(zoomPercent))
                }
                // Zoom re-lays out the whole document, so hold the reader's
                // place proportionally instead of letting it snap to the top.
                uiView.layoutIfNeeded()
                let maxOffset = max(0, uiView.contentSize.height - uiView.bounds.height)
                uiView.contentOffset.y = min(max(0, ratio * uiView.contentSize.height), maxOffset)
            }
            controller.scheduleRefresh()
            context.coordinator.scheduleSpellCheck()
        }

        context.coordinator.updateSpellLanguage(spellLanguage)
    }

    static func dismantleUIView(_ uiView: UITextView, coordinator: Coordinator) {
        coordinator.cancelPendingSpellCheck()
    }

    /// Mirrors `applyTeZoom` scaling the whole editor's `font-size`
    /// (app.js:1727-1732): a *display-only* transform, same as app.js's CSS
    /// `font-size` on the Quill root never touching the underlying Delta.
    /// `attributedText` (the model/binding, persisted as HTML via
    /// `HTMLConversion`) always stays at 100% — only the copy handed to
    /// `UITextView` is scaled; `modelText(_:)` scales back down before
    /// writing to the binding, so zoom never bakes into saved content.
    private func scaled(_ text: NSAttributedString) -> NSAttributedString {
        guard text.length > 0 else { return text }
        let mutable = resized(text, by: CGFloat(zoomPercent) / 100)
        // Ink goes on here, not in the model — see `EditorTypography.inkColor`.
        mutable.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: mutable.length)) { value, range, _ in
            guard value == nil else { return }
            mutable.addAttribute(.foregroundColor, value: EditorTypography.inkColor, range: range)
        }
        return mutable
    }

    fileprivate func modelText(_ text: NSAttributedString) -> NSAttributedString {
        guard text.length > 0 else { return text }
        let mutable = resized(text, by: 100 / CGFloat(zoomPercent))
        mutable.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: mutable.length)) { value, range, _ in
            guard let color = value as? UIColor, EditorTypography.isInk(color) else { return }
            mutable.removeAttribute(.foregroundColor, range: range)
        }
        return mutable
    }

    private func resized(_ text: NSAttributedString, by scale: CGFloat) -> NSMutableAttributedString {
        let mutable = NSMutableAttributedString(attributedString: text)
        guard zoomPercent != 100 else { return mutable }
        mutable.enumerateAttribute(.font, in: NSRange(location: 0, length: mutable.length)) { value, range, _ in
            let base = (value as? UIFont) ?? EditorTypography.body
            mutable.addAttribute(.font, value: base.withSize(base.pointSize * scale), range: range)
        }
        return mutable
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichTextView
        var isEditingInternally = false
        var lastAppliedZoom = EditorZoom.default
        weak var textView: EditorTextView?

        private let spellSession = SpellCheckSession()
        private var spellWorkItem: DispatchWorkItem?

        init(_ parent: RichTextView) {
            self.parent = parent
        }

        // MARK: Text + selection

        func textViewDidChange(_ textView: UITextView) {
            isEditingInternally = true
            parent.attributedText = parent.modelText(textView.attributedText)
            isEditingInternally = false
            scheduleSpellCheck()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.selectedRange = textView.selectedRange
            parent.controller.scheduleRefresh()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // New text scrolls into view unchecked, so re-run the pass for
            // wherever the reader landed.
            scheduleSpellCheck()
        }

        // MARK: Spell checking

        func updateSpellLanguage(_ language: String?) {
            guard spellSession.language != language else { return }
            spellSession.language = language
            runSpellCheck()
        }

        func scheduleSpellCheck() {
            guard spellSession.language != nil else { return }
            spellWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.runSpellCheck() }
            spellWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
        }

        func cancelPendingSpellCheck() {
            spellWorkItem?.cancel()
            spellWorkItem = nil
        }

        private func runSpellCheck() {
            guard let textView else { return }
            textView.spellOverlay.ranges = spellSession.recheck(textView)
        }

        /// Puts corrections back where the system pass used to offer them:
        /// select (or long-press) a flagged word and the menu leads with
        /// `UITextChecker`'s guesses for the chosen language.
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard spellSession.language != nil,
                  let misspelled = spellSession.range(intersecting: range),
                  NSMaxRange(misspelled) <= (textView.text as NSString).length else { return nil }
            let word = (textView.text as NSString).substring(with: misspelled)
            let guesses = spellSession.guesses(for: misspelled, in: textView.text).prefix(4)

            var corrections: [UIMenuElement] = guesses.map { guess in
                UIAction(title: guess) { [weak self] _ in
                    self?.replace(misspelled, with: guess, in: textView)
                }
            }
            corrections.append(UIAction(title: String(localized: "Learn Spelling"), image: UIImage(systemName: "character.book.closed")) { [weak self] _ in
                self?.spellSession.learn(word: word)
                self?.runSpellCheck()
            })
            return UIMenu(children: [UIMenu(options: .displayInline, children: corrections)] + suggestedActions)
        }

        private func replace(_ range: NSRange, with replacement: String, in textView: UITextView) {
            guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                  let end = textView.position(from: start, offset: range.length),
                  let textRange = textView.textRange(from: start, to: end) else { return }
            // `replace(_:withText:)` rather than a storage edit: it inherits
            // the surrounding run's attributes and registers an undo step.
            textView.replace(textRange, withText: replacement)
            runSpellCheck()
        }
    }
}
