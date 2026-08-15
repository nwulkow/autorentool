import SwiftUI

/// Mirrors app.js's Character Relationship Map (app.js:2027-2077,
/// `canvasNodes`/`computedLinks`/link-mode methods at app.js:333-334,
/// 397-403, 999-1058): characters placed as draggable nodes on a pane, with
/// relation lines drawn between linked nodes.
///
/// Touch adaptation: app.js drags a character chip onto the pane via native
/// HTML drag-and-drop, which has no direct touch equivalent. Here, adding a
/// node is tap-to-add from the character pool (same pattern as
/// `TimelineView`'s `CharacterPoolBar`); repositioning an already-placed
/// node is still a `DragGesture`, same as the JS mousedown/mousemove pair.
/// Link mode (tap two nodes to connect them) carries over directly since it
/// was already tap-driven in the web version.
struct CanvasView: View {
    @ObservedObject var editor: BookEditor

    @State private var linkMode = false
    @State private var linkSourceId: String?
    @State private var selectedNodeId: String?
    @State private var linkModal: LinkModalState?

    private struct LinkModalState: Identifiable {
        let id = UUID()
        let character1Id: String
        let character2Id: String
        var relationType: String = ""
    }

    var body: some View {
        Group {
            if editor.book.characters.isEmpty {
                EmptyStateView(
                    systemImage: "point.3.connected.trianglepath.dotted",
                    title: String(localized: "No characters yet."),
                    message: String(localized: "Add characters first, then place them on the map."),
                    actionTitle: nil, action: nil
                )
            } else {
                VStack(spacing: 0) {
                    header
                    characterPool
                    if linkMode {
                        Text("Tap two characters on the map to link them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                    }
                    canvasPane
                    if !editor.book.characterRelations.isEmpty {
                        relationsList
                    }
                }
            }
        }
        .sheet(item: $linkModal) { modal in
            LinkModalView(
                editor: editor,
                character1Id: modal.character1Id,
                character2Id: modal.character2Id,
                onCreate: { relationType in
                    editor.book.characterRelations.append(
                        CharacterRelation(character1Id: modal.character1Id, character2Id: modal.character2Id, relationType: relationType)
                    )
                    cancelLinkMode()
                },
                onCancel: { cancelLinkMode() }
            )
        }
    }

    /// Mirrors `map-header`/`map-actions` (app.js:2029-2038). Placed inline
    /// rather than in `.toolbar` — tab content views in `BookTabContainer`
    /// don't get their toolbars merged into the shared nav bar (only the
    /// container's own toolbar does), matching `TimelineView`'s in-body
    /// toolbar convention.
    private var header: some View {
        HStack {
            Text("Relationship Map")
                .font(Theme.sectionTitle)
                .foregroundStyle(Theme.ink)
            Spacer()
            if linkMode {
                Button("Cancel", role: .destructive) { cancelLinkMode() }
                    .font(.subheadline)
            } else {
                Button {
                    linkMode = true
                    linkSourceId = nil
                    selectedNodeId = nil
                } label: {
                    Label("Add Link", systemImage: "link")
                        .font(.subheadline)
                }
                .disabled(editor.book.canvasNodes.count < 2)
            }
        }
        .padding(8)
    }

    /// Mirrors `canvas-chips` (app.js:2043-2048) — tap-to-place stand-in for drag-onto-map.
    private var characterPool: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("Add to map:").font(.caption).foregroundStyle(.secondary)
                ForEach(editor.book.characters) { character in
                    let placed = editor.book.canvasNodes.contains { $0.characterId == character.id }
                    Button {
                        guard !placed else { return }
                        addNode(for: character.id)
                    } label: {
                        Text(character.name)
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .overlay(Capsule().stroke(CharacterPalette.color(for: character.id, in: editor.book.characters), lineWidth: 1.5))
                            .opacity(placed ? 0.4 : 1)
                    }
                    .disabled(placed)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
    }

    /// Mirrors `canvas-pane`/`canvas-svg` (app.js:2050-2066) — relation
    /// lines drawn under the nodes, links computed from live node positions.
    private var canvasPane: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                // `.canvas-pane`'s warm off-white (styles.css:239), not the
                // system's cool gray.
                Theme.canvasGround

                Canvas { context, _ in
                    for link in computedLinks {
                        var path = Path()
                        path.move(to: CGPoint(x: link.x1, y: link.y1))
                        path.addLine(to: CGPoint(x: link.x2, y: link.y2))
                        context.stroke(path, with: .color(Color(hex: 0x7aa5f0)), lineWidth: 2)

                        let midpoint = CGPoint(x: (link.x1 + link.x2) / 2, y: (link.y1 + link.y2) / 2)
                        context.draw(
                            Text(link.label).font(.caption2).bold().foregroundStyle(Color(hex: 0x4a6fa5)),
                            at: midpoint
                        )
                    }
                }

                ForEach(editor.book.canvasNodes, id: \.characterId) { node in
                    CanvasNodeView(
                        editor: editor,
                        node: node,
                        isLinkSource: linkSourceId == node.characterId,
                        isSelected: !linkMode && selectedNodeId == node.characterId,
                        linkMode: linkMode,
                        onMove: { newX, newY in moveNode(node.characterId, x: newX, y: newY) },
                        onTap: { handleNodeTap(node.characterId) },
                        onRemove: { removeNode(node.characterId) }
                    )
                }

                if editor.book.canvasNodes.isEmpty {
                    ContentUnavailableView("Add characters to the map", systemImage: "point.3.connected.trianglepath.dotted")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { selectedNodeId = nil }
        }
        .frame(minHeight: 360)
    }

    /// Mirrors `rel-list` (app.js:2069-2077).
    private var relationsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Relations")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.muted)
                .textCase(.uppercase)
            ForEach(editor.book.characterRelations) { relation in
                HStack {
                    Text(charName(relation.character1Id))
                        .foregroundStyle(CharacterPalette.color(for: relation.character1Id, in: editor.book.characters))
                    Text(relation.relationType).font(.caption).foregroundStyle(.secondary)
                    Text(charName(relation.character2Id))
                        .foregroundStyle(CharacterPalette.color(for: relation.character2Id, in: editor.book.characters))
                    Spacer()
                    Button {
                        editor.book.characterRelations.removeAll { $0.id == relation.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }
        }
        .padding(8)
    }

    private struct ComputedLink: Identifiable {
        let id: String
        let x1, y1, x2, y2: Double
        let label: String
    }

    /// Mirrors `computedLinks` (app.js:396-403) — node anchor is its
    /// center, approximated the same way as the web version (fixed offset
    /// from top-left: +66/+18, half of the ~132×36 node size).
    private var computedLinks: [ComputedLink] {
        editor.book.characterRelations.compactMap { relation in
            guard let n1 = editor.book.canvasNodes.first(where: { $0.characterId == relation.character1Id }),
                  let n2 = editor.book.canvasNodes.first(where: { $0.characterId == relation.character2Id }) else { return nil }
            return ComputedLink(id: relation.id, x1: n1.x + 66, y1: n1.y + 18, x2: n2.x + 66, y2: n2.y + 18, label: relation.relationType)
        }
    }

    private func charName(_ id: String?) -> String {
        guard let id else { return "General" }
        return editor.book.characters.first { $0.id == id }?.name ?? "Unknown"
    }

    /// Mirrors `onCanvasDrop` (app.js:1001-1007), placement point simplified
    /// to a cascading default position rather than a drop coordinate.
    private func addNode(for characterId: String) {
        let index = editor.book.canvasNodes.count
        let x = 16 + Double((index % 4)) * 150
        let y = 16 + Double((index / 4)) * 90
        editor.book.canvasNodes.append(CanvasNode(characterId: characterId, x: x, y: y))
    }

    private func moveNode(_ characterId: String, x: Double, y: Double) {
        guard let index = editor.book.canvasNodes.firstIndex(where: { $0.characterId == characterId }) else { return }
        editor.book.canvasNodes[index].x = max(0, x)
        editor.book.canvasNodes[index].y = max(0, y)
    }

    /// Mirrors `onNodeClick` (app.js:1029-1046).
    private func handleNodeTap(_ characterId: String) {
        if linkMode {
            if linkSourceId == nil {
                linkSourceId = characterId
            } else if linkSourceId != characterId {
                linkModal = LinkModalState(character1Id: linkSourceId!, character2Id: characterId)
            }
            return
        }
        selectedNodeId = (selectedNodeId == characterId) ? nil : characterId
    }

    /// Mirrors `removeNode` (app.js:1054-1058).
    private func removeNode(_ characterId: String) {
        editor.book.canvasNodes.removeAll { $0.characterId == characterId }
        editor.book.characterRelations.removeAll { $0.character1Id == characterId || $0.character2Id == characterId }
        if selectedNodeId == characterId { selectedNodeId = nil }
    }

    private func cancelLinkMode() {
        linkMode = false
        linkSourceId = nil
        linkModal = nil
    }
}

/// One draggable node — mirrors `canvas-node` (app.js:2058-2064).
private struct CanvasNodeView: View {
    @ObservedObject var editor: BookEditor
    let node: CanvasNode
    let isLinkSource: Bool
    let isSelected: Bool
    let linkMode: Bool
    let onMove: (Double, Double) -> Void
    let onTap: () -> Void
    let onRemove: () -> Void

    @State private var dragStart: (x: Double, y: Double)?

    private var name: String {
        editor.book.characters.first { $0.id == node.characterId }?.name ?? "Unknown"
    }
    private var color: Color { CharacterPalette.color(for: node.characterId, in: editor.book.characters) }
    private var lightColor: Color { CharacterPalette.lightColor(for: node.characterId, in: editor.book.characters) }

    var body: some View {
        HStack(spacing: 4) {
            Text(name).font(.caption).lineLimit(1)
            if !linkMode {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(minWidth: 100)
        .background(lightColor)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color, lineWidth: isLinkSource || isSelected ? 3 : 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .position(x: node.x + 66, y: node.y + 18)
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { drag in
                    if dragStart == nil { dragStart = (node.x, node.y) }
                    guard let dragStart else { return }
                    onMove(dragStart.x + drag.translation.width, dragStart.y + drag.translation.height)
                }
                .onEnded { _ in dragStart = nil }
        )
        .onTapGesture { onTap() }
    }
}

/// Mirrors the link modal (app.js:2879-2892).
private struct LinkModalView: View {
    @ObservedObject var editor: BookEditor
    let character1Id: String
    let character2Id: String
    let onCreate: (String) -> Void
    let onCancel: () -> Void

    @State private var relationType: String = ""
    @Environment(\.dismiss) private var dismiss

    private func charName(_ id: String) -> String {
        editor.book.characters.first { $0.id == id }?.name ?? "Unknown"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(charName(character1Id))
                            .foregroundStyle(CharacterPalette.color(for: character1Id, in: editor.book.characters))
                        Image(systemName: "arrow.left.arrow.right")
                            .foregroundStyle(.secondary)
                        Text(charName(character2Id))
                            .foregroundStyle(CharacterPalette.color(for: character2Id, in: editor.book.characters))
                    }
                }
                Section("Relation type") {
                    TextField("e.g. friends, rivals", text: $relationType)
                }
            }
            .navigationTitle("Create Relation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create Link") {
                        let trimmed = relationType.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        onCreate(trimmed)
                        dismiss()
                    }
                    .disabled(relationType.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
