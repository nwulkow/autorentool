import SwiftUI

/// One location's map editor — the tool palette, the scrollable canvas, and
/// the selected object's properties. Mirrors app.js's `.loc-editor`
/// (app.js:2375-2568).
///
/// Two deliberate departures from the web version, both forced by touch:
/// - the properties panel is a bottom sheet rather than a pane floating over
///   the canvas, which on a ~390pt-wide phone would cover most of the map;
/// - finishing an area is an explicit **Finish** button rather than a
///   double-click or a tap near the first point (app.js:1364-1371) — both are
///   too imprecise under a fingertip to be the only way to close a polygon.
struct LocationEditorView: View {
    @ObservedObject var editor: BookEditor
    let locationId: String

    @State private var tool: LocationTools.Tool = .select
    @State private var selectedObjectId: String?
    @State private var draftPoints: [[Double]] = []
    @State private var showingProperties = false

    /// Writes straight back into the book so every edit flows through
    /// `BookEditor`'s debounced autosave, the same as every other tab.
    private var locationBinding: Binding<Location>? {
        guard let index = editor.book.locations.firstIndex(where: { $0.id == locationId }) else { return nil }
        return Binding(
            get: { editor.book.locations[index] },
            set: { editor.book.locations[index] = $0 }
        )
    }

    var body: some View {
        Group {
            if let binding = locationBinding {
                VStack(spacing: 0) {
                    toolPalette
                    if case .area(let area) = tool {
                        areaHintBar(area)
                    }
                    canvasArea(binding)
                }
                .navigationTitle(binding.wrappedValue.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingProperties = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .disabled(selectedObject(in: binding.wrappedValue) == nil)
                    }
                }
                .sheet(isPresented: $showingProperties) {
                    if let objectBinding = selectedObjectBinding(binding) {
                        LocationObjectPropertiesView(
                            object: objectBinding,
                            onDelete: {
                                binding.wrappedValue.objects.removeAll { $0.id == selectedObjectId }
                                selectedObjectId = nil
                                showingProperties = false
                            }
                        )
                    }
                }
            } else {
                EmptyStateView(
                    systemImage: "mappin.slash",
                    title: String(localized: "Location not found"),
                    message: String(localized: "It may have been deleted.")
                )
            }
        }
    }

    /// `.draw-tools` (app.js:2382-2394).
    private var toolPalette: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(LocationTools.allTools) { candidate in
                    Button {
                        // `selectDrawTool` (app.js:1380) — switching tools
                        // abandons any half-drawn area.
                        tool = candidate
                        draftPoints = []
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: candidate.symbol).font(.system(size: 16))
                            Text(candidate.label).font(.system(size: 9))
                        }
                        .foregroundStyle(tool == candidate ? Color.accentColor : .primary)
                        .frame(width: 52, height: 46)
                        .background(tool == candidate ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemBackground))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(tool == candidate ? Color.accentColor : .clear, lineWidth: 1.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    /// Replaces the web version's implicit "double-click or click the first
    /// point to close" affordance with something tappable.
    private func areaHintBar(_ area: LocationTools.Area) -> some View {
        HStack(spacing: 8) {
            Text(draftPoints.isEmpty
                 ? "Tap the map to outline the \(area.rawValue)."
                 : "\(draftPoints.count) point\(draftPoints.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !draftPoints.isEmpty {
                Button("Undo") { draftPoints.removeLast() }
                    .font(.caption)
                Button("Finish") { finishArea(area) }
                    .font(.caption.bold())
                    .disabled(draftPoints.count < area.minimumPoints)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private func canvasArea(_ binding: Binding<Location>) -> some View {
        ScrollView([.horizontal, .vertical]) {
            LocationMapCanvas(
                location: binding,
                tool: tool,
                selectedObjectId: $selectedObjectId,
                draftPoints: $draftPoints
            )
            .padding(8)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    /// `finishArea` (app.js:1373-1379).
    private func finishArea(_ area: LocationTools.Area) {
        guard let binding = locationBinding, draftPoints.count >= area.minimumPoints else {
            draftPoints = []
            return
        }
        let object = LocationObject(
            type: area.rawValue,
            x: 0, y: 0, width: 0, height: 0,
            color: area.defaultColor,
            stroke: area.defaultStroke,
            strokeWidth: area.defaultStrokeWidth,
            points: draftPoints
        )
        binding.wrappedValue.objects.append(object)
        selectedObjectId = object.id
        draftPoints = []
    }

    private func selectedObject(in location: Location) -> LocationObject? {
        guard let selectedObjectId else { return nil }
        return location.objects.first { $0.id == selectedObjectId }
    }

    private func selectedObjectBinding(_ location: Binding<Location>) -> Binding<LocationObject>? {
        guard let selectedObjectId,
              let index = location.wrappedValue.objects.firstIndex(where: { $0.id == selectedObjectId }) else { return nil }
        return Binding(
            get: { location.wrappedValue.objects[index] },
            set: { location.wrappedValue.objects[index] = $0 }
        )
    }
}

/// The `.prop-panel` (app.js:2397-2413), as a sheet. Which fields show
/// depends on the object's kind, the same way the web version's `v-if`s
/// branch on `points.length` and `ALL_ICONS.includes(type)`.
struct LocationObjectPropertiesView: View {
    @Binding var object: LocationObject
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var isPolygon: Bool { !object.points.isEmpty }
    private var isIcon: Bool {
        if case .icon = LocationTools.tool(forType: object.type) { return true }
        return false
    }

    /// `ColorPicker` binds a `Color`, but the model stores a CSS string whose
    /// alpha must survive editing — see `CSSColor` for why that matters to
    /// the Mac app.
    private func colorBinding(_ keyPath: WritableKeyPath<LocationObject, String>) -> Binding<Color> {
        Binding(
            get: { CSSColor.color(object[keyPath: keyPath]) },
            set: { object[keyPath: keyPath] = $0.cssString(preservingAlphaOf: object[keyPath: keyPath]) }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $object.name)
                }
                Section("Colors") {
                    ColorPicker("Fill", selection: colorBinding(\.color), supportsOpacity: false)
                    ColorPicker("Stroke", selection: colorBinding(\.stroke), supportsOpacity: false)
                    if isPolygon {
                        Stepper(
                            "Stroke width: \(Int(object.strokeWidth))",
                            value: $object.strokeWidth, in: 1...40, step: 1
                        )
                    }
                }
                if !isPolygon {
                    Section("Size") {
                        Stepper("Width: \(Int(object.width))", value: $object.width, in: 1...2000, step: 5)
                        Stepper("Height: \(Int(object.height))", value: $object.height, in: 1...2000, step: 5)
                    }
                }
                if isIcon {
                    Section("Scale") {
                        HStack {
                            Text("Scale")
                            Spacer()
                            Text(String(format: "%.1f×", object.scale)).foregroundStyle(.secondary)
                        }
                        Slider(value: $object.scale, in: 0.2...5, step: 0.1)
                    }
                }
                Section {
                    Button("Delete Object", role: .destructive, action: onDelete)
                }
            }
            .navigationTitle(LocationTools.tool(forType: object.type)?.label ?? object.type.capitalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
