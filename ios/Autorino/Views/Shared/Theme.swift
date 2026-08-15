import SwiftUI
import UIKit

/// Design tokens ported from the Vue app's `styles.css` `:root` block
/// (styles.css:5-19) so the iOS app reads as the same product rather than a
/// generic SwiftUI shell: warm paper cream instead of system gray, a tan
/// rule instead of the default separator, brown-black ink instead of pure
/// black, and the same blue accent.
///
/// The web app is light-only. Each token here is a dynamic color so dark
/// mode stays *warm* (dark brown/espresso) rather than falling back to a
/// neutral system gray that would lose the book feel entirely.
enum Theme {

    // MARK: - Palette (styles.css:5-19)

    /// `--bg` — the page/paper ground behind everything.
    static let paper = dynamic(light: 0xF8F6F1, dark: 0x1A1714)
    /// `--panel` — cards, rows, sheets sitting on the paper.
    static let panel = dynamic(light: 0xFFFFFF, dark: 0x262119)
    /// The sidebar's slightly deeper cream (styles.css:111), used here for
    /// toolbars/chrome bars that sit above content.
    static let chrome = dynamic(light: 0xF2EDE2, dark: 0x201C16)
    /// `--line` — warm tan hairline. Replaces the cool system separator.
    static let line = dynamic(light: 0xDDD6C8, dark: 0x3E362C)
    /// `--text` — warm near-black.
    static let ink = dynamic(light: 0x2C2720, dark: 0xF1EADD)
    /// `--muted` — warm brown-gray for secondary text.
    static let muted = dynamic(light: 0x8A7E72, dark: 0xA89A8A)
    /// `--accent` / `--accent-hover`.
    static let accent = dynamic(light: 0x4A7DFF, dark: 0x7098FF)
    /// The `#eef3ff` accent wash used behind active tabs/tag hovers
    /// (styles.css:126, 154, 215).
    static let accentSoft = dynamic(light: 0xEEF3FF, dark: 0x22304F)
    /// `--danger`.
    static let danger = dynamic(light: 0xE85454, dark: 0xFF6B6B)
    /// `.canvas-pane` / `.loc-canvas`'s drawing ground (styles.css:239).
    static let canvasGround = dynamic(light: 0xFAFAF8, dark: 0x14110E)

    // MARK: - Metrics (styles.css `--radius` / `--radius-sm`)

    static let radius: CGFloat = 12
    static let radiusSmall: CGFloat = 8

    // MARK: - Type

    /// The `.brand-name` serif stack (styles.css:87) — Palatino/Book
    /// Antiqua/Georgia. Georgia is the member of that stack guaranteed to
    /// ship on iOS, and `relativeTo:` keeps Dynamic Type working.
    static func serif(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("Georgia", size: size, relativeTo: style)
    }

    /// Screen/section titles — the book-jacket voice.
    static var title: Font { serif(28, relativeTo: .largeTitle) }
    static var sectionTitle: Font { serif(20, relativeTo: .title3) }
    /// Row headlines (a character's name, a chapter title).
    static var rowTitle: Font { serif(17, relativeTo: .headline) }

    // MARK: - UIKit chrome

    /// SwiftUI can't restyle the navigation/tab bars from a modifier, so the
    /// warm ground and the serif title are pushed through `UIAppearance`
    /// once at launch. Without this the bars keep the system gray and the
    /// paper look stops at the content edge.
    static func applyGlobalAppearance() {
        let ink = UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0xF1EADD) : UIColor(rgb: 0x2C2720) }
        let ground = UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x1A1714) : UIColor(rgb: 0xF8F6F1) }
        let hairline = UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x3E362C) : UIColor(rgb: 0xDDD6C8) }

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = ground
        nav.shadowColor = hairline
        nav.titleTextAttributes = [
            .foregroundColor: ink,
            .font: UIFont(name: "Georgia-Bold", size: 17) ?? .boldSystemFont(ofSize: 17),
        ]
        // Only the inline title gets the serif treatment. The iOS 26 large
        // title doesn't render reliably with a custom font through the
        // appearance proxy (it came out blank), so screens that want a big
        // serif heading draw one in their own content instead — see
        // `BookListView`'s header.
        nav.largeTitleTextAttributes = [.foregroundColor: ink]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x201C16) : UIColor(rgb: 0xF2EDE2) }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }

    // MARK: - Helpers

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Reusable surface styling

extension View {
    /// Puts content on the warm paper ground and drops `List`/`Form`'s own
    /// system background so the cream shows through (styles.css `body`).
    func paperBackground() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.paper)
    }

    /// The `.book-card` / `.panel` treatment (styles.css:94-98, 166-170):
    /// white panel, tan hairline border, soft shadow, 12pt radius.
    func bookCard(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .stroke(Theme.line, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 1)
    }

    /// Makes a `List` row carry the card look: transparent row, paper
    /// ground, inset spacing. Pair with `.paperBackground()` on the list.
    func bookCardRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
    }
}

/// The pill used for tag chips and the segmented switches — mirrors
/// `.eo-tag-chip` (styles.css:140-142) and `.char-tag` (styles.css:195).
struct BookChipStyle: ViewModifier {
    var active: Bool = false

    func body(content: Content) -> some View {
        content
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(active ? Color.white : Theme.accent)
            .background(active ? Theme.accent : Theme.accentSoft, in: Capsule())
            .overlay(Capsule().stroke(active ? Theme.accent : Theme.line, lineWidth: 1))
    }
}

extension View {
    func bookChip(active: Bool = false) -> some View {
        modifier(BookChipStyle(active: active))
    }
}

/// A two-or-more-way switch styled like the web app's tag chips rather than
/// `.pickerStyle(.segmented)`, whose gray capsule reads as system chrome and
/// fights the paper look. Used to fold Canvas into Characters and Questions
/// into Notes (see `CharactersTabView` / `NotesTabView`).
struct BookSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String, systemImage: String)]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.value) { option in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = option.value }
                } label: {
                    Label(option.label, systemImage: option.systemImage)
                        .bookChip(active: selection == option.value)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.chrome)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line), alignment: .bottom)
    }
}
