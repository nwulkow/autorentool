import SwiftUI

/// Characters and the relationship map are two views of the same thing —
/// who's in the book and how they connect — so they share one tab instead
/// of the two separate ones the first tab layout had. The switch replaces
/// what was a top-level tab of its own (`CanvasView`), matching app.js
/// where the map is also character-scoped (app.js:2027-2077).
struct CharactersTabView: View {
    @ObservedObject var editor: BookEditor

    enum Mode: Hashable { case list, map }
    @State private var mode: Mode = .list

    var body: some View {
        VStack(spacing: 0) {
            BookSegmentedControl(
                selection: $mode,
                options: [
                    (value: .list, label: String(localized: "People"), systemImage: "person.2"),
                    (value: .map, label: String(localized: "Relationships"), systemImage: "point.3.connected.trianglepath.dotted"),
                ]
            )

            switch mode {
            case .list: CharactersListView(editor: editor)
            case .map: CanvasView(editor: editor)
            }
        }
        .background(Theme.paper)
        .navigationTitle("Characters")
    }
}
