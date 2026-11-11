import SwiftUI

/// One location's map editor — the tool palette, the pan/zoom canvas, and
/// the selected object's actions. Mirrors app.js's `.loc-editor`
/// (app.js:2375-2568).
///
/// Departures from the web version, all forced by touch:
/// - the properties panel is a bottom sheet rather than a pane floating over
///   the canvas, which on a ~390pt-wide phone would cover most of the map;
///   a selection bar over the canvas carries the quick actions (duplicate,
///   arrange, delete) the desktop gets from the panel and the keyboard;
/// - finishing an area is an explicit **Finish** button rather than a
///   double-click or a tap near the first point (app.js:1364-1371) — both are
///   too imprecise under a fingertip to be the only way to close a polygon.
///
/// The sparkles menu is iOS-only: a chat about the place (the map described
/// as text, see `LocationGeneration.describe`) and "Generate objects", which
/// only ever *adds* to the map and can be undone from the banner it leaves.
struct LocationEditorView: View {
    @ObservedObject var editor: BookEditor
    let locationId: String

    @State private var tool: LocationTools.Tool = .select
    @State private var selection: Set<String> = []
    /// Taps add/remove objects and a drag draws a selection rectangle, so
    /// several objects can be moved, duplicated or deleted together.
    @State private var multiSelect = false
    @State private var draftPoints: [[Double]] = []
    @State private var showingProperties = false
    @State private var showingLLM = false
    @State private var showingGenerate = false
    /// The last generated batch, for the Undo banner.
    @State private var generated: (ids: Set<String>, note: String)?

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
                LLMAssistantHost(
                    editor: editor,
                    isPresented: $showingLLM,
                    persist: false,
                    baseContext: LocationGeneration.describe(binding.wrappedValue),
                    title: binding.wrappedValue.name,
                    starters: Self.starters
                ) {
                    content(binding)
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

    /// Chat starters about the place, replacing the chapter ones.
    private static let starters: [String] = [
        String(localized: "What would make this place more vivid?"),
        String(localized: "Does the layout match how the chapters describe it?"),
        String(localized: "What's missing for the scenes set here?"),
        String(localized: "Where could someone hide or watch unseen?"),
    ]

    private func content(_ binding: Binding<Location>) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                toolPalette
                Divider().frame(height: 34)
                assistantMenu
            }
            .background(Color(uiColor: .systemGroupedBackground))
            if multiSelect {
                multiSelectHintBar
            } else if case .area(let area) = tool {
                areaHintBar(area)
            }
            LocationMapCanvas(
                location: binding,
                tool: tool,
                selection: $selection,
                multiSelect: multiSelect,
                draftPoints: $draftPoints
            )
            .overlay(alignment: .top) {
                if let generated {
                    generatedBanner(generated, binding)
                }
            }
            .overlay(alignment: .bottom) {
                let selected = binding.wrappedValue.objects.filter { selection.contains($0.id) }
                if !selected.isEmpty || multiSelect {
                    selectionBar(selected, binding)
                }
            }
        }
        .navigationTitle(binding.wrappedValue.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingProperties) {
            if let objectBinding = selectedObjectBinding(binding) {
                LocationObjectPropertiesView(
                    object: objectBinding,
                    onDelete: {
                        deleteSelected(binding)
                        showingProperties = false
                    }
                )
            }
        }
        .sheet(isPresented: $showingGenerate) {
            LocationGenerateSheet(location: binding.wrappedValue, book: editor.book) { objects, note in
                add(objects, to: binding)
                generated = (Set(objects.map(\.id)), note)
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
                        multiSelect = false
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
    }

    /// In the view body rather than the nav bar, because on regular width the
    /// assistant host is a split view whose columns don't merge their
    /// toolbars into this screen's (same reason `TimelineView` does it).
    private var assistantMenu: some View {
        Menu {
            Button { showingLLM = true } label: {
                Label("Ask about this place", systemImage: "bubble.left.and.text.bubble.right")
            }
            Button { showingGenerate = true } label: {
                Label("Generate objects…", systemImage: "wand.and.stars")
            }
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 18))
                .frame(width: 48, height: 46)
        }
        .accessibilityLabel(Text("Assistant"))
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

    private func selectionBar(_ selected: [LocationObject], _ binding: Binding<Location>) -> some View {
        HStack(spacing: 4) {
            if selected.count == 1, let object = selected.first {
                Image(systemName: LocationTools.tool(forType: object.type)?.symbol ?? "questionmark")
                    .foregroundStyle(.secondary)
                Text(object.name.isEmpty ? (LocationTools.tool(forType: object.type)?.label ?? object.type) : object.name)
                    .font(.subheadline)
                    .lineLimit(1)
            } else {
                Text(String(localized: "\(selected.count) selected"))
                    .font(.subheadline)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                multiSelect.toggle()
                draftPoints = []
            } label: {
                Image(systemName: "checkmark.circle.badge.plus")
                    .frame(width: 40, height: 40)
                    .foregroundStyle(multiSelect ? Color.white : Color.accentColor)
                    .background(multiSelect ? Color.accentColor : .clear, in: Circle())
            }
            .accessibilityLabel(Text("Select Multiple"))
            barButton("Duplicate", systemImage: "plus.square.on.square") { duplicateSelected(binding) }
                .disabled(selected.isEmpty)
            if selected.count <= 1 {
                barButton("Edit", systemImage: "slider.horizontal.3") { showingProperties = true }
                    .disabled(selected.isEmpty)
            }
            Menu {
                Button { reorderSelected(binding, toFront: true) } label: {
                    Label("Bring to Front", systemImage: "square.3.layers.3d.top.filled")
                }
                Button { reorderSelected(binding, toFront: false) } label: {
                    Label("Send to Back", systemImage: "square.3.layers.3d.bottom.filled")
                }
            } label: {
                Image(systemName: "square.3.layers.3d")
                    .frame(width: 40, height: 40)
            }
            .disabled(selected.isEmpty)
            .accessibilityLabel(Text("Arrange"))
            barButton("Delete", systemImage: "trash", tint: .red) { deleteSelected(binding) }
                .disabled(selected.isEmpty)
            barButton("Deselect", systemImage: "xmark") {
                selection = []
                multiSelect = false
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private var multiSelectHintBar: some View {
        HStack(spacing: 8) {
            Text("Tap objects to add or remove them, or drag a rectangle. Two fingers pan.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { multiSelect = false }
                .font(.caption.bold())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private func barButton(_ title: LocalizedStringKey, systemImage: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 40, height: 40)
                .foregroundStyle(tint ?? Color.accentColor)
        }
        .accessibilityLabel(Text(title))
    }

    private func generatedBanner(_ batch: (ids: Set<String>, note: String), _ binding: Binding<Location>) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wand.and.stars").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(batch.ids.count == 1 ? String(localized: "Added 1 object") : String(localized: "Added \(batch.ids.count) objects"))
                    .font(.subheadline.weight(.semibold))
                if !batch.note.isEmpty {
                    Text(batch.note).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }
            }
            Spacer(minLength: 4)
            Button("Undo") {
                binding.wrappedValue.objects.removeAll { batch.ids.contains($0.id) }
                selection.subtract(batch.ids)
                generated = nil
            }
            .font(.subheadline)
            Button { generated = nil } label: { Image(systemName: "xmark") }
                .accessibilityLabel(Text("Dismiss"))
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 10)
        .padding(.top, 10)
        // Leave the fit button (top trailing) reachable.
        .padding(.trailing, 46)
    }

    // MARK: - Actions

    /// `finishArea` (app.js:1373-1379).
    private func finishArea(_ area: LocationTools.Area) {
        guard let binding = locationBinding, draftPoints.count >= area.minimumPoints else {
            draftPoints = []
            return
        }
        let object = LocationTools.adoptingStyle(
            LocationObject(
                type: area.rawValue,
                x: 0, y: 0, width: 0, height: 0,
                color: area.defaultColor,
                stroke: area.defaultStroke,
                strokeWidth: area.defaultStrokeWidth,
                points: draftPoints
            ),
            from: LocationTools.styleTemplate(forType: area.rawValue, in: binding.wrappedValue)
        )
        binding.wrappedValue.objects.append(object)
        selection = [object.id]
        draftPoints = []
    }

    /// Each copy goes directly above its original, so the stacking order
    /// among the copies matches the originals'.
    private func duplicateSelected(_ binding: Binding<Location>) {
        var copies: Set<String> = []
        for index in binding.wrappedValue.objects.indices.reversed() where selection.contains(binding.wrappedValue.objects[index].id) {
            let copy = LocationTools.duplicate(binding.wrappedValue.objects[index])
            binding.wrappedValue.objects.insert(copy, at: index + 1)
            copies.insert(copy.id)
        }
        selection = copies
    }

    private func deleteSelected(_ binding: Binding<Location>) {
        binding.wrappedValue.objects.removeAll { selection.contains($0.id) }
        selection = []
    }

    /// Z-order is array order (drawn first = bottom), as in app.js's SVG.
    /// The selection moves as a block, keeping its own internal order.
    private func reorderSelected(_ binding: Binding<Location>, toFront: Bool) {
        let objects = binding.wrappedValue.objects
        let moving = objects.filter { selection.contains($0.id) }
        let rest = objects.filter { !selection.contains($0.id) }
        binding.wrappedValue.objects = toFront ? rest + moving : moving + rest
    }

    /// Generated areas go in just above the existing areas, so a new lake
    /// doesn't cover the cars already parked beside it; everything else on top.
    private func add(_ objects: [LocationObject], to binding: Binding<Location>) {
        let isArea: (LocationObject) -> Bool = { LocationTools.tool(forType: $0.type)?.isArea == true }
        var insertAt = (binding.wrappedValue.objects.lastIndex(where: isArea) ?? -1) + 1
        for object in objects {
            if isArea(object) {
                binding.wrappedValue.objects.insert(object, at: insertAt)
                insertAt += 1
            } else {
                binding.wrappedValue.objects.append(object)
            }
        }
    }

    private func selectedObjectBinding(_ location: Binding<Location>) -> Binding<LocationObject>? {
        guard selection.count == 1, let selectedId = selection.first,
              let index = location.wrappedValue.objects.firstIndex(where: { $0.id == selectedId }) else { return nil }
        return Binding(
            get: { location.wrappedValue.objects[index] },
            set: { location.wrappedValue.objects[index] = $0 }
        )
    }
}

/// "Generate objects…": the writer describes what the place needs, the model
/// lays it out (`LLMService.locationObjects`). Nothing on the map is changed
/// or removed — the answer is only ever appended, and `LocationEditorView`
/// offers Undo for the batch.
struct LocationGenerateSheet: View {
    let location: Location
    let book: Book
    let onAdd: (_ objects: [LocationObject], _ note: String) -> Void

    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    /// Shared with every assistant pane, so the pick made in the chat applies here.
    @AppStorage("geminiSelectedModel") private var selectedModel: String = GeminiModelCatalog.defaultModel
    @AppStorage("geminiThinkingLevel") private var thinkingSetting: ThinkingSetting = .auto
    @AppStorage("geminiTemperature") private var temperature: Double = 1.0

    @State private var request = ""
    /// On by default when there is anything to send: a place generated
    /// without the book invents a layout the chapters may already contradict.
    @State private var includeDigests = true
    @State private var isLoading = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    private var trimmedRequest: String { request.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var digestEntries: [PromptBuilder.DigestContextEntry] {
        env.digestService.store(for: book.title).promptEntries(in: book)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. a village square with a fountain, three houses and a road leading north", text: $request, axis: .vertical)
                        .lineLimit(3...8)
                        .disabled(isLoading)
                } header: {
                    Text("What should be added?")
                } footer: {
                    Text(location.objects.isEmpty
                         ? String(localized: "The map is empty; the model lays out the place from scratch.")
                         : String(localized: "The model sees the \(location.objects.count) objects already on the map and only adds new ones."))
                }
                Section {
                    Toggle(isOn: $includeDigests) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use chapter summaries")
                            Text(digestEntries.isEmpty
                                 ? String(localized: "No chapter summaries yet.")
                                 : String(localized: "\(digestEntries.count) chapters — places, names and details the story already fixes."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(digestEntries.isEmpty || isLoading)
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).font(.callout)
                    }
                }
                Section {
                    Button {
                        generate()
                    } label: {
                        HStack {
                            if isLoading { ProgressView().padding(.trailing, 6) }
                            Text(isLoading ? String(localized: "Generating…") : String(localized: "Generate"))
                        }
                    }
                    .disabled(trimmedRequest.isEmpty || isLoading)
                } footer: {
                    Text(selectedModel)
                }
            }
            .navigationTitle("Generate Objects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        task?.cancel()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isLoading)
    }

    private func generate() {
        error = nil
        isLoading = true
        let request = trimmedRequest
        let bookContext = includeDigests
            ? PromptBuilder.digestContextText(digestEntries, totalChapters: book.chapters.count)
            : ""
        task = Task {
            defer { isLoading = false }
            do {
                let (payload, _) = try await env.llmService.locationObjects(
                    for: location,
                    request: request,
                    bookContext: bookContext,
                    model: selectedModel,
                    settings: GenerationSettings(thinkingLevel: thinkingSetting.level, temperature: min(max(temperature, 0), 1))
                )
                let objects = LocationGeneration.objects(from: payload, for: location)
                guard !objects.isEmpty else {
                    error = String(localized: "The model suggested nothing that fits on the map. Try describing it differently.")
                    return
                }
                onAdd(objects, payload.note)
                dismiss()
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
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
