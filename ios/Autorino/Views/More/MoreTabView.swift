import SwiftUI

/// The fifth tab. Holds the parts of the book that don't earn a permanent
/// slot in the bar — Locations today — plus a way into Settings without
/// backing all the way out to the book list.
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

            Section {
                NavigationLink {
                    SettingsView()
                } label: {
                    MoreRow(
                        title: String(localized: "Settings"),
                        subtitle: String(localized: "Sync, Gemini key, conflicts"),
                        systemImage: "gearshape",
                        tint: Theme.muted
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
