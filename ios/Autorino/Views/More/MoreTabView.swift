import SwiftUI

/// The fifth tab. Holds the parts of the book that don't earn a permanent
/// slot in the bar — Locations today. Settings lives behind the gear icon
/// in `BookTabContainer`'s toolbar instead (mirroring the book list's own
/// top-right gear in `RootView`), presented as a sheet — not pushed here —
/// because `SettingsView` wraps its own `NavigationStack` and a
/// `dismiss()`-driven Done button, which only behaves correctly when
/// presented modally. Pushing it via `NavigationLink` nested a
/// `NavigationStack` inside a pushed destination of the outer stack that
/// owns `BookListView`'s `path`, which could pop more levels than intended
/// and leave `path` out of sync with what was on screen (taps on a book
/// afterwards silently did nothing).
struct MoreTabView: View {
    @ObservedObject var editor: BookEditor

    var body: some View {
        List {
            Section {
                NavigationLink {
                    LocationsListView(editor: editor)
                } label: {
                    MoreRow(
                        title: String(localized: "Locations"),
                        subtitle: locationsSubtitle,
                        systemImage: "mappin.and.ellipse",
                        tint: Theme.accent
                    )
                }
                .bookCardRow()
            }
        }
        .listStyle(.plain)
        .paperBackground()
        .navigationTitle("More")
    }

    private var locationsSubtitle: String {
        let count = editor.book.locations.count
        return count == 1
            ? String(localized: "1 place")
            : String(localized: "\(count) places")
    }
}

private struct MoreRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.rowTitle).foregroundStyle(Theme.ink)
                Text(subtitle).font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, 4)
        .bookCard(padding: 12)
    }
}
