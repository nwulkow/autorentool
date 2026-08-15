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
                    title: "No event orders yet.",
                    message: "Build a timeline of events per character.",
                    actionTitle: "+ New Event Order"
                ) { addEventOrder() }
            } else {
                List {
                    ForEach(editor.book.eventOrders) { order in
                        NavigationLink {
                            TimelineView(editor: editor, orderId: order.id)
                        } label: {
                            EventOrderRow(order: order)
                        }
                    }
                    .onDelete { indexSet in
                        editor.book.eventOrders.remove(atOffsets: indexSet)
                    }
                }
            }
        }
        .navigationTitle("Event Orders")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { addEventOrder() } label: { Label("New Event Order", systemImage: "plus") }
            }
        }
    }

    /// Mirrors `addEventOrder` (app.js:1060-1066).
    private func addEventOrder() {
        let order = EventOrder(name: "Event Order \(editor.book.eventOrders.count + 1)")
        editor.book.eventOrders.append(order)
    }
}

private struct EventOrderRow: View {
    let order: EventOrder

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(order.name).font(.headline)
            Text("\(order.characterColumns.count) columns")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
