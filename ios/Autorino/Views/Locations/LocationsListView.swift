import SwiftUI

/// Mirrors app.js's Locations tab list (`.loc-list`, app.js:2367-2373, and
/// `addLocation`/`deleteLocation`, app.js:1313-1322): the book's locations,
/// each opening into `LocationEditorView`.
struct LocationsListView: View {
    @ObservedObject var editor: BookEditor

    @State private var showingNewLocation = false

    var body: some View {
        Group {
            if editor.book.locations.isEmpty {
                EmptyStateView(
                    systemImage: "mappin.and.ellipse",
                    title: "No locations yet.",
                    message: "Draw maps of the places in your story.",
                    actionTitle: "+ New Location"
                ) { showingNewLocation = true }
            } else {
                List {
                    ForEach(editor.book.locations) { location in
                        NavigationLink {
                            LocationEditorView(editor: editor, locationId: location.id)
                        } label: {
                            LocationRow(location: location)
                        }
                    }
                    .onDelete { indexSet in
                        editor.book.locations.remove(atOffsets: indexSet)
                    }
                }
            }
        }
        .navigationTitle("Locations")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingNewLocation = true } label: { Label("New Location", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showingNewLocation) {
            NewLocationSheet { location in
                editor.book.locations.append(location)
            }
        }
    }
}

private struct LocationRow: View {
    let location: Location

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(location.name).font(.headline)
            Text("\(LocationTools.tickLabel(location.width))×\(LocationTools.tickLabel(location.height)) \(location.unit) · \(location.objects.count) object\(location.objects.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !location.description.isEmpty {
                Text(location.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Mirrors the inline "new location" form (`newLoc`, app.js:1314-1320) —
/// name, description, and the map's dimensions in a unit of the writer's
/// choosing.
private struct NewLocationSheet: View {
    let onCreate: (Location) -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var width = "10"
    @State private var height = "10"
    @State private var unit = "m"
    @Environment(\.dismiss) private var dismiss

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section("Size") {
                    HStack {
                        Text("Width")
                        Spacer()
                        TextField("10", text: $width)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    HStack {
                        Text("Height")
                        Spacer()
                        TextField("10", text: $height)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    HStack {
                        Text("Unit")
                        Spacer()
                        TextField("m", text: $unit)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                }
            }
            .navigationTitle("New Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        // Same fallbacks as app.js:1316 — a blank or
                        // unparseable dimension becomes 10, not 0.
                        onCreate(Location(
                            name: trimmedName,
                            description: description.trimmingCharacters(in: .whitespaces),
                            width: Double(width) ?? 10,
                            height: Double(height) ?? 10,
                            unit: unit.trimmingCharacters(in: .whitespaces).isEmpty ? "m" : unit.trimmingCharacters(in: .whitespaces)
                        ))
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
