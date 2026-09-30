import SwiftUI

/// Mirrors the `tl-editor` timeline grid (app.js:2097-2257): a fixed axis of
/// time markers alongside one scrollable column per character (plus an
/// optional "General" column), with events placed/dragged/resized by
/// vertical position. The LLM assistant side panel (app.js:2259-2320,
/// `runEoLlmPrompt`) reuses `LLMAssistantHost`/`LLMAssistantSheet` rather
/// than growing its own chat surface — `persist: false` and `baseContext:
/// PromptBuilder.eventOrderPrompt(...)` reproduce `runEoLlmPrompt`'s
/// `persist:false` history and its `text` (the event-order dump) sent
/// alongside every turn (app.js:516-545).
///
/// Touch adaptation: app.js drags characters onto columns and drags column
/// headers to reorder via native HTML drag-and-drop, which has no direct
/// touch equivalent. Here, adding a column is tap-to-add from the character
/// pool and reordering is a "Move" menu on the column header — same
/// underlying model mutations (`characterColumns` insert/move/remove), just
/// touch-first affordances instead of a drag source.
///
/// The axis and the column headers are *frozen panes*, not part of the
/// scrolled content: on desktop the whole grid fits, on a phone a timeline
/// scrolled right and down showed neither the time nor whose column an
/// event sat in. `TimelineGrid` therefore scrolls only the cells and
/// counter-offsets the two sticky panes by the reported scroll offset.
struct TimelineView: View {
    @ObservedObject var editor: BookEditor
    let orderId: String

    @State private var configOpen = false
    @State private var selectedTags: Set<String> = []
    @State private var editingEventId: String?
    @State private var showingLLM = false
    /// One shared focus for every text field on this screen, so there is a
    /// single keyboard accessory with one "Done" — SwiftUI merges `.keyboard`
    /// toolbars, so a per-field one would stack up several Done buttons.
    @FocusState private var focus: TimelineFocus?

    private var orderIndex: Int? {
        editor.book.eventOrders.firstIndex { $0.id == orderId }
    }

    var body: some View {
        Group {
            if let orderIndex {
                LLMAssistantHost(
                    editor: editor,
                    isPresented: $showingLLM,
                    defaultScope: assistantScope(editor.book.eventOrders[orderIndex]),
                    persist: false,
                    baseContext: PromptBuilder.eventOrderPrompt(editor.book.eventOrders[orderIndex], characters: editor.book.characters),
                    title: editor.book.eventOrders[orderIndex].name
                ) {
                    content(orderIndex: orderIndex)
                }
            } else {
                EmptyStateView(systemImage: "clock.arrow.circlepath", title: String(localized: "Event order not found."), message: "", actionTitle: nil, action: nil)
            }
        }
    }

    /// Every character that has a column on this timeline, pre-ticked in the
    /// assistant's scope picker. app.js leaves `llmSelectedCharIds` empty
    /// until the user checks boxes, but on a timeline the columns *are* the
    /// cast under discussion — asking "would she really do this?" shouldn't
    /// first require re-selecting the people already on screen. The rows stay
    /// editable, so anyone can still be unticked.
    private func assistantScope(_ order: EventOrder) -> [ContentScopeItem] {
        var seen = Set<String>()
        return order.characterColumns
            .compactMap(\.characterId)
            .filter { id in
                guard editor.book.characters.contains(where: { $0.id == id }) else { return false }
                return seen.insert(id).inserted
            }
            .map { ContentScopeItem(kind: .character, id: $0) }
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
                    title: String(localized: "No columns yet."),
                    message: String(localized: "Add characters from above or a General column, then tap the timeline to place events."),
                    actionTitle: nil, action: nil
                )
            } else {
                TimelineGrid(editor: editor, order: order, selectedTags: selectedTags, editingEventId: $editingEventId, focus: $focus)
            }
        }
        .navigationTitle(order.wrappedValue.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Without this there is no way off an event's description field:
            // it's a multi-line field, so Return inserts a newline, and the
            // block's own Done button can be underneath the keyboard.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    focus = nil
                    editingEventId = nil
                }
            }
        }
    }

    @ViewBuilder
    private func toolbar(order: Binding<EventOrder>) -> some View {
        HStack {
            TextField("Name", text: order.name)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .orderName)
                .submitLabel(.done)
            Button {
                focus = nil
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

            LLMAssistantButton(isPresented: $showingLLM)
        }
        .padding(8)
    }
}

/// Which text field on the timeline currently holds the keyboard.
enum TimelineFocus: Hashable {
    case orderName
    case event(String)
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

/// The axis + columns scroll surface (app.js:2184-2257), as three panes: a
/// horizontally-frozen time axis on the left, a vertically-frozen header row
/// of character names on top, and the cells, which are the only part that
/// actually scrolls. The frozen panes render the same content as before —
/// they're just translated by the scroll offset instead of riding along
/// inside the `ScrollView`.
///
/// Freezing needs the live scroll offset, and `onScrollGeometryChange` is the
/// only API that reliably reports it — the pre-18 idiom of reading the
/// content's frame through a preference key measurably never fires under the
/// current scroll implementation. Rather than ship panes that silently stick
/// at the top-left, iOS 17 keeps the original layout, with the axis and the
/// headers scrolling along inside the grid.
private struct TimelineGrid: View {
    @ObservedObject var editor: BookEditor
    @Binding var order: EventOrder
    let selectedTags: Set<String>
    @Binding var editingEventId: String?
    @FocusState.Binding var focus: TimelineFocus?

    @State private var scrollOffset: CGPoint = .zero

    private static let axisWidth: CGFloat = 64
    private static let columnWidth: CGFloat = 220
    private static let headerHeight: CGFloat = 34

    private var markers: [TimelineMarker] { TimelineMath.generateMarkers(order.timelineConfig) }

    /// How tall the scrollable cells are. The timeline's own height is the
    /// floor, but an event can be dragged or resized past the last marker, so
    /// the lowest event's bottom edge wins when it's further down — otherwise
    /// that event is simply unreachable.
    private var contentHeight: Double {
        let axisHeight = TimelineGeometry.totalHeight(order: order)
        let lowestEvent = order.characterColumns.flatMap(\.events).map { $0.yPos + $0.height }.max() ?? 0
        return max(axisHeight, lowestEvent + 24)
    }

    /// Dead space below the last row. While an event is being edited it grows
    /// to roughly a keyboard's height, so the bottom-most block can be
    /// scrolled clear of the keyboard and its text actually tapped into.
    private var bottomSlack: CGFloat { editingEventId == nil ? 80 : 360 }

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
        if #available(iOS 18.0, *) {
            frozenPaneLayout
        } else {
            scrollingHeaderLayout
        }
    }

    @available(iOS 18.0, *)
    private var frozenPaneLayout: some View {
        // The frozen panes hold content far wider and taller than the screen,
        // and a `.frame(maxWidth:/maxHeight: .infinity)` around an oversized
        // child reports the *child's* size — which pushed the whole screen
        // sideways. Measuring once here and pinning each pane to an exact
        // frame is what makes the clipping actually clip.
        GeometryReader { geo in
            let gridHeight = max(0, geo.size.height - Self.headerHeight)
            VStack(spacing: 0) {
                headerRow(width: geo.size.width)
                HStack(spacing: 0) {
                    axisPane(height: gridHeight)
                    cellsScrollView
                }
                .frame(width: geo.size.width, height: gridHeight, alignment: .topLeading)
            }
        }
    }

    /// Frozen top pane: the corner cell plus the character names, slid
    /// horizontally to match the cells below.
    private func headerRow(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color(uiColor: .secondarySystemBackground)
                .frame(width: Self.axisWidth)
            HStack(spacing: 0) {
                ForEach(filteredColumnIndices, id: \.self) { colIndex in
                    ColumnHeader(editor: editor, order: $order, colIndex: colIndex)
                        .frame(width: Self.columnWidth, height: Self.headerHeight)
                }
            }
            .offset(x: -scrollOffset.x)
            .frame(width: max(0, width - Self.axisWidth), height: Self.headerHeight, alignment: .topLeading)
            .clipped()
        }
        .frame(width: width, height: Self.headerHeight, alignment: .topLeading)
        .overlay(Divider(), alignment: .bottom)
        .zIndex(1)
    }

    /// Frozen left pane: the time markers, slid vertically to match the cells
    /// beside them.
    private func axisPane(height: CGFloat) -> some View {
        AxisColumn(order: $order, markers: markers, totalHeight: contentHeight)
            .offset(y: -scrollOffset.y)
            .frame(width: Self.axisWidth, height: height, alignment: .topLeading)
            .clipped()
            .overlay(Divider(), alignment: .trailing)
            .zIndex(1)
    }

    @available(iOS 18.0, *)
    private var cellsScrollView: some View {
        ScrollView([.horizontal, .vertical]) {
            columnsRow
        }
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: CGPoint.self) { geometry in
            CGPoint(
                x: geometry.contentOffset.x + geometry.contentInsets.leading,
                y: geometry.contentOffset.y + geometry.contentInsets.top
            )
        } action: { _, offset in
            scrollOffset = offset
        }
        .animation(.easeOut(duration: 0.2), value: bottomSlack)
    }

    /// Pre-18 layout: one scroll surface with the axis and the column headers
    /// riding along inside it, as app.js's grid does.
    private var scrollingHeaderLayout: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 0) {
                AxisColumn(order: $order, markers: markers, totalHeight: contentHeight)
                    .padding(.top, Self.headerHeight)
                ForEach(filteredColumnIndices, id: \.self) { colIndex in
                    VStack(spacing: 0) {
                        ColumnHeader(editor: editor, order: $order, colIndex: colIndex)
                            .frame(height: Self.headerHeight)
                        columnBody(colIndex)
                    }
                    .frame(width: Self.columnWidth)
                }
            }
            .padding(.bottom, bottomSlack)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var columnsRow: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(filteredColumnIndices, id: \.self) { colIndex in
                columnBody(colIndex)
                    .frame(width: Self.columnWidth)
            }
        }
        .padding(.bottom, bottomSlack)
    }

    private func columnBody(_ colIndex: Int) -> some View {
        ColumnBody(
            editor: editor,
            order: $order,
            colIndex: colIndex,
            markers: markers,
            totalHeight: contentHeight,
            editingEventId: $editingEventId,
            focus: $focus
        )
    }
}

/// Mirrors `tl-axis` (app.js:2186-2199) plus the gap grow/shrink buttons.
private struct AxisColumn: View {
    @Binding var order: EventOrder
    let markers: [TimelineMarker]
    let totalHeight: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(uiColor: .secondarySystemBackground)
                .frame(width: 64, height: CGFloat(totalHeight))
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
        .frame(width: 64, height: CGFloat(totalHeight), alignment: .top)
    }
}

/// A column's frozen header — name plus the move/remove menu, mirroring
/// `tl-col`'s header (app.js:2202-2212). Lives outside the scroll view so
/// it stays readable however far the grid is scrolled down.
private struct ColumnHeader: View {
    @ObservedObject var editor: BookEditor
    @Binding var order: EventOrder
    let colIndex: Int

    private var characterId: String? {
        guard colIndex < order.characterColumns.count else { return nil }
        return order.characterColumns[colIndex].characterId
    }
    private var color: Color { CharacterPalette.color(for: characterId, in: editor.book.characters) }
    private var lightColor: Color { CharacterPalette.lightColor(for: characterId, in: editor.book.characters) }
    private var name: String {
        guard let characterId else { return "General" }
        return editor.book.characters.first { $0.id == characterId }?.name ?? "Unknown"
    }

    var body: some View {
        HStack {
            Text(name).font(.caption).fontWeight(.semibold).lineLimit(1)
            Spacer()
            Menu {
                Button("Move left") { move(by: -1) }
                Button("Move right") { move(by: 1) }
                Button("Remove column", role: .destructive) { removeColumn() }
            } label: {
                Image(systemName: "ellipsis.circle").font(.caption)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(lightColor)
        .overlay(Rectangle().frame(height: 2).foregroundStyle(color), alignment: .bottom)
    }

    /// Mirrors `removeColumn` (app.js:1119-1122).
    private func removeColumn() {
        guard colIndex < order.characterColumns.count else { return }
        order.characterColumns.remove(at: colIndex)
    }

    /// Touch-first stand-in for `onColDragStart`/`onColDrop`'s reordering
    /// (app.js:1123-1177) — same splice-and-reinsert, triggered from a menu
    /// instead of a drag gesture.
    private func move(by offset: Int) {
        let newIndex = colIndex + offset
        guard colIndex < order.characterColumns.count,
              newIndex >= 0, newIndex < order.characterColumns.count else { return }
        order.characterColumns.swapAt(colIndex, newIndex)
    }
}

/// One column's cells: event blocks placed by `yPos`/`height` over the
/// marker gridlines, mirroring `tl-evt` (app.js:2215-2251).
private struct ColumnBody: View {
    @ObservedObject var editor: BookEditor
    @Binding var order: EventOrder
    let colIndex: Int
    let markers: [TimelineMarker]
    let totalHeight: Double
    @Binding var editingEventId: String?
    @FocusState.Binding var focus: TimelineFocus?

    private var characterId: String? {
        guard colIndex < order.characterColumns.count else { return nil }
        return order.characterColumns[colIndex].characterId
    }
    private var color: Color { CharacterPalette.color(for: characterId, in: editor.book.characters) }
    private var lightColor: Color { CharacterPalette.lightColor(for: characterId, in: editor.book.characters) }

    var body: some View {
        if colIndex < order.characterColumns.count {
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
                        editingEventId: $editingEventId,
                        focus: $focus
                    )
                }
            }
            .frame(height: CGFloat(totalHeight), alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { location in
                addEvent(at: location.y)
            }
        }
    }

    /// Mirrors `onTlColDblClick` (app.js:1270-1277). Clamped against the
    /// axis height, not the (possibly taller) scroll content — new events
    /// belong on the timeline proper.
    private func addEvent(at y: Double) {
        let axisHeight = TimelineGeometry.totalHeight(order: order)
        let clampedY = min(max(y - 25, 16), max(16, axisHeight - 50))
        let time = TimelineMath.timeFromY(clampedY, markers: markers, cfg: order.timelineConfig)
        let event = Event(description: "", yPos: clampedY, height: 50, time: time, locationId: nil)
        order.characterColumns[colIndex].events.append(event)
        editingEventId = event.id
        focus = .event(event.id)
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
    @FocusState.Binding var focus: TimelineFocus?

    @State private var dragStartY: Double?
    @State private var resizeStartHeight: Double?

    private var eventIndex: Int? {
        guard colIndex < order.characterColumns.count else { return nil }
        return order.characterColumns[colIndex].events.firstIndex { $0.id == eventId }
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
                    .focused($focus, equals: .event(event.id))

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
                        Button("Done") {
                            focus = nil
                            editingEventId = nil
                        }
                        .font(.caption2)
                    }
                } else {
                    Text(event.description.isEmpty ? String(localized: "(tap to edit)") : event.description)
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
                    if focus == .event(event.id) { focus = nil }
                    if editingEventId == event.id { editingEventId = nil }
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
                        let limit = max(16, TimelineGeometry.totalHeight(order: order) - event.height)
                        let newY = min(max((dragStartY ?? event.yPos) + drag.translation.height, 16), limit)
                        order.characterColumns[colIndex].events[eventIndex].yPos = newY
                        order.characterColumns[colIndex].events[eventIndex].time = TimelineMath.timeFromY(newY, markers: markers, cfg: order.timelineConfig)
                    }
                    .onEnded { _ in dragStartY = nil }
            )
            .onTapGesture(count: 2) {
                editingEventId = event.id
                focus = .event(event.id)
            }
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
