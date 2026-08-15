import SwiftUI

/// Mirrors the `tl-editor` timeline grid (app.js:2097-2257): a fixed axis of
/// time markers alongside one scrollable column per character (plus an
/// optional "General" column), with events placed/dragged/resized by
/// vertical position. The LLM assistant side panel (app.js:2259+) is
/// deferred — it duplicates `LLMAssistantSheet`'s machinery and belongs in
/// its own pass rather than growing this view further.
///
/// Touch adaptation: app.js drags characters onto columns and drags column
/// headers to reorder via native HTML drag-and-drop, which has no direct
/// touch equivalent. Here, adding a column is tap-to-add from the character
/// pool and reordering is a "Move" menu on the column header — same
/// underlying model mutations (`characterColumns` insert/move/remove), just
/// touch-first affordances instead of a drag source.
struct TimelineView: View {
    @ObservedObject var editor: BookEditor
    let orderId: String

    @State private var configOpen = false
    @State private var selectedTags: Set<String> = []
    @State private var editingEventId: String?

    private var orderIndex: Int? {
        editor.book.eventOrders.firstIndex { $0.id == orderId }
    }

    var body: some View {
        Group {
            if let orderIndex {
                content(orderIndex: orderIndex)
            } else {
                EmptyStateView(systemImage: "clock.arrow.circlepath", title: "Event order not found.", message: "", actionTitle: nil, action: nil)
            }
        }
    }

    @ViewBuilder
    private func content(orderIndex: Int) -> some View {
        let order = Binding(
            get: { editor.book.eventOrders[orderIndex] },
            set: { editor.book.eventOrders[orderIndex] = $0 }
        )

        VStack(spacing: 0) {
            toolbar(order: order)

            if configOpen {
                TimelineConfigView(order: order)
                    .frame(maxHeight: 320)
                    .overlay(Divider(), alignment: .bottom)
            }

            CharacterPoolBar(editor: editor, order: order, selectedTags: $selectedTags)

            if order.wrappedValue.characterColumns.isEmpty {
                EmptyStateView(
                    systemImage: "clock.arrow.circlepath",
                    title: "No columns yet.",
                    message: "Add characters from above or a General column, then tap the timeline to place events.",
                    actionTitle: nil, action: nil
                )
            } else {
                TimelineGrid(editor: editor, order: order, selectedTags: selectedTags, editingEventId: $editingEventId)
            }
        }
        .navigationTitle(order.wrappedValue.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func toolbar(order: Binding<EventOrder>) -> some View {
        HStack {
            TextField("Name", text: order.name)
                .textFieldStyle(.roundedBorder)
            Button {
                configOpen.toggle()
            } label: {
                Label("Timeline", systemImage: "gearshape")
            }
            HStack(spacing: 4) {
                Button {
                    TimelineGeometry.setPixelsPerMarker(order.wrappedValue.timelineConfig.pixelsPerMarker - 10, order: &editor.book.eventOrders[editor.book.eventOrders.firstIndex(where: { $0.id == orderId })!])
                } label: { Image(systemName: "minus.circle") }
                Text("\(Int(order.wrappedValue.timelineConfig.pixelsPerMarker))px").font(.caption).foregroundStyle(.secondary)
                Button {
                    TimelineGeometry.setPixelsPerMarker(order.wrappedValue.timelineConfig.pixelsPerMarker + 10, order: &editor.book.eventOrders[editor.book.eventOrders.firstIndex(where: { $0.id == orderId })!])
                } label: { Image(systemName: "plus.circle") }
            }
            .buttonStyle(.plain)
        }
        .padding(8)
    }
}

/// Mirrors the character drop pool + tag filter (app.js:2160-2179).
private struct CharacterPoolBar: View {
    @ObservedObject var editor: BookEditor
    @Binding var order: EventOrder
    @Binding var selectedTags: Set<String>

    private var allTags: [String] {
        var tags = Set(editor.book.tags)
        for character in editor.book.characters { tags.formUnion(character.tags) }
        return tags.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("Add character:").font(.caption).foregroundStyle(.secondary)
                    ForEach(editor.book.characters) { character in
                        let used = order.characterColumns.contains { $0.characterId == character.id }
                        Button {
                            guard !used else { return }
                            order.characterColumns.append(CharacterColumn(characterId: character.id, events: []))
                        } label: {
                            Text(character.name)
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .overlay(Capsule().stroke(CharacterPalette.color(for: character.id, in: editor.book.characters), lineWidth: 1.5))
                                .opacity(used ? 0.4 : 1)
                        }
                        .disabled(used)
                    }
                    Button {
                        guard !order.characterColumns.contains(where: { $0.characterId == nil }) else { return }
                        order.characterColumns.append(CharacterColumn(characterId: nil, events: []))
                    } label: {
                        Label("General", systemImage: "plus")
                            .font(.caption)
                    }
                    .disabled(order.characterColumns.contains { $0.characterId == nil })
                }
                .padding(.horizontal, 8)
            }

            if !allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Filter by tags:").font(.caption).foregroundStyle(.secondary)
                        ForEach(allTags, id: \.self) { tag in
                            let active = selectedTags.contains(tag)
                            Button {
                                if active { selectedTags.remove(tag) } else { selectedTags.insert(tag) }
                            } label: {
                                Text(tag).font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Capsule().fill(active ? Color.accentColor : Color.accentColor.opacity(0.12)))
                                    .foregroundStyle(active ? Color.white : Color.accentColor)
                            }
                        }
                        if !selectedTags.isEmpty {
                            Button("+ Add matching") { addCharactersBySelectedTags() }
                                .font(.caption2)
                            Button {
                                selectedTags = []
                            } label: {
                                Label("Clear", systemImage: "xmark")
                                    .font(.caption2)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Mirrors `addCharsBySelectedTags` (app.js:1109-1118).
    private func addCharactersBySelectedTags() {
        let matches = editor.book.characters.filter { character in
            selectedTags.allSatisfy { character.tags.contains($0) }
        }
        for character in matches where !order.characterColumns.contains(where: { $0.characterId == character.id }) {
            order.characterColumns.append(CharacterColumn(characterId: character.id, events: []))
        }
    }
}

/// The axis + columns scroll surface (app.js:2184-2257).
private struct TimelineGrid: View {
    @ObservedObject var editor: BookEditor
    @Binding var order: EventOrder
    let selectedTags: Set<String>
    @Binding var editingEventId: String?

    private var markers: [TimelineMarker] { TimelineMath.generateMarkers(order.timelineConfig) }
    private var totalHeight: Double { TimelineGeometry.totalHeight(order: order) }

    /// Mirrors `filteredOrderColumns` (app.js:380-388): General always
    /// shown, character columns filtered to those whose character carries
    /// every selected tag.
    private var filteredColumnIndices: [Int] {
        guard !selectedTags.isEmpty else { return Array(order.characterColumns.indices) }
        return order.characterColumns.indices.filter { index in
            guard let characterId = order.characterColumns[index].characterId else { return true }
            guard let character = editor.book.characters.first(where: { $0.id == characterId }) else { return false }
            return selectedTags.isSubset(of: Set(character.tags))
        }
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 0) {
                AxisColumn(order: $order, markers: markers, totalHeight: totalHeight)
                ForEach(filteredColumnIndices, id: \.self) { colIndex in
                    ColumnView(
                        editor: editor,
                        order: $order,
                        colIndex: colIndex,
                        markers: markers,
                        totalHeight: totalHeight,
                        editingEventId: $editingEventId
                    )
                    .frame(width: 220)
                }
            }
        }
    }
}

/// Mirrors `tl-axis` (app.js:2186-2199) plus the gap grow/shrink buttons.
private struct AxisColumn: View {
    @Binding var order: EventOrder
    let markers: [TimelineMarker]
    let totalHeight: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: 64, height: CGFloat(totalHeight))
            ForEach(markers, id: \.index) { marker in
                HStack(spacing: 4) {
                    Text(marker.label).font(.caption2)
                    VStack(spacing: 2) {
                        Button { TimelineGeometry.growGap(marker.index, order: &order) } label: {
                            Image(systemName: "plus.circle").font(.system(size: 10))
                        }
                        Button { TimelineGeometry.shrinkGap(marker.index, order: &order) } label: {
                            Image(systemName: "minus.circle").font(.system(size: 10))
                        }
                    }
                    .buttonStyle(.plain)
                }
                .position(x: 32, y: CGFloat(TimelineGeometry.markerY(marker.index, order: order)))
            }
        }
        .frame(width: 64)
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

/// One character (or General) column: header + event blocks placed by
/// `yPos`/`height`, mirroring `tl-col`/`tl-evt` (app.js:2202-2251).
private struct ColumnView: View {
    @ObservedObject var editor: BookEditor
    @Binding var order: EventOrder
    let colIndex: Int
    let markers: [TimelineMarker]
    let totalHeight: Double
    @Binding var editingEventId: String?

    private var characterId: String? { order.characterColumns[colIndex].characterId }
    private var color: Color { CharacterPalette.color(for: characterId, in: editor.book.characters) }
    private var lightColor: Color { CharacterPalette.lightColor(for: characterId, in: editor.book.characters) }
    private var name: String {
        guard let characterId else { return "General" }
        return editor.book.characters.first { $0.id == characterId }?.name ?? "Unknown"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(name).font(.caption).fontWeight(.semibold)
                Spacer()
                Menu {
                    Button("Move left") { move(by: -1) }
                    Button("Move right") { move(by: 1) }
                    Button("Remove column", role: .destructive) { removeColumn() }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.caption)
                }
            }
            .padding(6)
            .background(lightColor)
            .overlay(Rectangle().frame(height: 2).foregroundStyle(color), alignment: .bottom)

            GeometryReader { _ in
                ZStack(alignment: .topLeading) {
                    lightColor.opacity(0.3)
                    ForEach(markers, id: \.index) { marker in
                        Divider()
                            .offset(y: CGFloat(TimelineGeometry.markerY(marker.index, order: order)))
                    }
                    ForEach(order.characterColumns[colIndex].events) { event in
                        EventBlock(
                            editor: editor,
                            order: $order,
                            colIndex: colIndex,
                            eventId: event.id,
                            color: color,
                            totalHeight: totalHeight,
                            markers: markers,
                            editingEventId: $editingEventId
                        )
                    }
                }
                .frame(height: CGFloat(totalHeight), alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { location in
                    addEvent(at: location.y)
                }
            }
            .frame(height: CGFloat(totalHeight))
        }
    }

    /// Mirrors `onTlColDblClick` (app.js:1270-1277).
    private func addEvent(at y: Double) {
        let clampedY = min(max(y - 25, 16), totalHeight - 50)
        let time = TimelineMath.timeFromY(clampedY, markers: markers, cfg: order.timelineConfig)
        let event = Event(description: "", yPos: clampedY, height: 50, time: time, locationId: nil)
        order.characterColumns[colIndex].events.append(event)
        editingEventId = event.id
    }

    /// Mirrors `removeColumn` (app.js:1119-1122).
    private func removeColumn() {
        order.characterColumns.remove(at: colIndex)
    }

    /// Touch-first stand-in for `onColDragStart`/`onColDrop`'s reordering
    /// (app.js:1123-1177) — same splice-and-reinsert, triggered from a menu
    /// instead of a drag gesture.
    private func move(by offset: Int) {
        let newIndex = colIndex + offset
        guard newIndex >= 0, newIndex < order.characterColumns.count else { return }
        order.characterColumns.swapAt(colIndex, newIndex)
    }
}

/// One event block: drag to move, handle to resize, tap to edit — mirrors
/// `tl-evt` (app.js:2215-2249) adapted from mouse drag to `DragGesture`.
private struct EventBlock: View {
    @ObservedObject var editor: BookEditor
    @Binding var order: EventOrder
    let colIndex: Int
    let eventId: String
    let color: Color
    let totalHeight: Double
    let markers: [TimelineMarker]
    @Binding var editingEventId: String?

    @State private var dragStartY: Double?
    @State private var resizeStartHeight: Double?

    private var eventIndex: Int? {
        order.characterColumns[colIndex].events.firstIndex { $0.id == eventId }
    }

    var body: some View {
        if let eventIndex {
            let event = order.characterColumns[colIndex].events[eventIndex]
            let isEditing = editingEventId == event.id

            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    TextField("Describe event…", text: Binding(
                        get: { order.characterColumns[colIndex].events[eventIndex].description },
                        set: { order.characterColumns[colIndex].events[eventIndex].description = $0 }
                    ), axis: .vertical)
                    .font(.caption)
                    .textFieldStyle(.plain)

                    Picker("Location", selection: Binding(
                        get: { order.characterColumns[colIndex].events[eventIndex].locationId },
                        set: { order.characterColumns[colIndex].events[eventIndex].locationId = $0 }
                    )) {
                        Text("No location").tag(String?.none)
                        ForEach(editor.book.locations) { loc in
                            Text(loc.name).tag(String?.some(loc.id))
                        }
                    }
                    .font(.caption2)
                    .pickerStyle(.menu)

                    HStack {
                        Text(event.time).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Done") { editingEventId = nil }
                            .font(.caption2)
                    }
                } else {
                    Text(event.description.isEmpty ? "(tap to edit)" : event.description)
                        .font(.caption)
                        .lineLimit(2)
                    HStack {
                        if let locationId = event.locationId,
                           let loc = editor.book.locations.first(where: { $0.id == locationId }) {
                            Text("📍 \(loc.name)").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(event.time).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, minHeight: CGFloat(event.height), alignment: .topLeading)
            .background(Color(uiColor: .systemBackground))
            .overlay(Rectangle().frame(width: 3).foregroundStyle(color), alignment: .leading)
            .overlay(alignment: .bottomTrailing) {
                if !isEditing {
                    resizeHandle(event: event)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    order.characterColumns[colIndex].events.remove(at: eventIndex)
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(2)
            }
            .shadow(radius: isEditing ? 4 : 1)
            .offset(y: CGFloat(event.yPos))
            .gesture(
                isEditing ? nil :
                DragGesture(minimumDistance: 4)
                    .onChanged { drag in
                        if dragStartY == nil { dragStartY = event.yPos }
                        let newY = min(max((dragStartY ?? event.yPos) + drag.translation.height, 16), totalHeight - event.height)
                        order.characterColumns[colIndex].events[eventIndex].yPos = newY
                        order.characterColumns[colIndex].events[eventIndex].time = TimelineMath.timeFromY(newY, markers: markers, cfg: order.timelineConfig)
                    }
                    .onEnded { _ in dragStartY = nil }
            )
            .onTapGesture(count: 2) { editingEventId = event.id }
        }
    }

    @ViewBuilder
    private func resizeHandle(event: Event) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .padding(4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { drag in
                        guard let eventIndex else { return }
                        if resizeStartHeight == nil { resizeStartHeight = event.height }
                        let newHeight = min(max((resizeStartHeight ?? event.height) + drag.translation.height, 24), 600)
                        order.characterColumns[colIndex].events[eventIndex].height = newHeight
                        order.characterColumns[colIndex].events[eventIndex].time = TimelineMath.timeFromY(event.yPos, markers: markers, cfg: order.timelineConfig)
                    }
                    .onEnded { _ in resizeStartHeight = nil }
            )
    }
}
