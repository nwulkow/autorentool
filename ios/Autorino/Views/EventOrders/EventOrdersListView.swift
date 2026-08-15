import SwiftUI

/// Mirrors app.js's Event orders tab shell (app.js:2081-2096, `addEventOrder`/
/// `deleteEventOrder`/`selectOrder`, app.js:1060-1073): a flat list of
/// timelines belonging to the book, each opening into `TimelineView`.
struct EventOrdersListView: View {
    @ObservedObject var editor: BookEditor

    var body: some View {
        Group {
            if editor.book.eventOrders.isEmpty {
                EmptyStateView(
                    systemImage: "clock.arrow.circlepath",
                    title: String(localized: "No event orders yet."),
                    message: String(localized: "Build a timeline of events per character."),
                    actionTitle: String(localized: "+ New Event Order")
                ) { addEventOrder() }
            } else {
                List {
                    ForEach(editor.book.eventOrders) { order in
                        NavigationLink {
                            TimelineView(editor: editor, orderId: order.id)
                        } label: {
                            EventOrderRow(order: order)
                        }
                        .bookCardRow()
                    }
                    .onDelete { indexSet in
                        editor.book.eventOrders.remove(atOffsets: indexSet)
                    }
                }
                .listStyle(.plain)
                .paperBackground()
                .safeAreaInset(edge: .bottom) {
                    AddBarButton(title: String(localized: "New Event Order")) { addEventOrder() }
                }
            }
        }
        .background(Theme.paper)
        .navigationTitle("Event Orders")
    }

    /// Mirrors `addEventOrder` (app.js:1060-1066).
    private func addEventOrder() {
        let order = EventOrder(name: "Event Order \(editor.book.eventOrders.count + 1)")
        editor.book.eventOrders.append(order)
    }
}

private struct EventOrderRow: View {
    let order: EventOrder

    private var eventCount: Int {
        order.characterColumns.reduce(0) { $0 + $1.events.count }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(order.name)
                    .font(Theme.rowTitle)
                    .foregroundStyle(Theme.ink)
                Text("\(order.characterColumns.count) columns · \(eventCount) events")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
        }
        .bookCard(padding: 14)
    }
}
