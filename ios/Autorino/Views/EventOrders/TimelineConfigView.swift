import SwiftUI

/// Mirrors the `tl-config` panel (app.js:2110-2157): timeline mode, per-mode
/// fields, and — for custom mode — a reorderable label list. Custom-label
/// insert/remove also has to keep already-placed events' `yPos` in sync with
/// whichever gap they now sit in/after, ported from `insertCustomLabel`/
/// `removeCustomLabel` (app.js:1186-1226) via `TimelineGeometry`.
struct TimelineConfigView: View {
    @Binding var order: EventOrder

    var body: some View {
        Form {
            Section("Mode") {
                Picker("Mode", selection: $order.timelineConfig.mode) {
                    Text("Custom Labels").tag(TimelineConfig.Mode.custom)
                    Text("Clock (hours)").tag(TimelineConfig.Mode.clock)
                    Text("Days of Week").tag(TimelineConfig.Mode.weekday)
                    Text("Weeks").tag(TimelineConfig.Mode.week)
                    Text("Months").tag(TimelineConfig.Mode.month)
                    Text("Dates").tag(TimelineConfig.Mode.date)
                }
                Stepper(value: $order.timelineConfig.pixelsPerMarker, in: 30...300, step: 10) {
                    HStack {
                        Text("Pixels per marker")
                        Spacer()
                        Text("\(Int(order.timelineConfig.pixelsPerMarker))px").foregroundStyle(.secondary)
                    }
                }
            }

            switch order.timelineConfig.mode {
            case .clock:
                Section("Clock") {
                    TextField("Start (08:00)", text: $order.timelineConfig.clockStart)
                    TextField("End (20:00)", text: $order.timelineConfig.clockEnd)
                    Stepper(value: $order.timelineConfig.clockIntervalMin, in: 5...240, step: 5) {
                        HStack {
                            Text("Interval (min)")
                            Spacer()
                            Text("\(order.timelineConfig.clockIntervalMin)").foregroundStyle(.secondary)
                        }
                    }
                }
            case .week:
                Section("Weeks") {
                    Stepper("Start week: \(order.timelineConfig.weekStart)", value: $order.timelineConfig.weekStart, in: 1...52)
                    Stepper("End week: \(order.timelineConfig.weekEnd)", value: $order.timelineConfig.weekEnd, in: 1...52)
                }
            case .date:
                Section("Dates") {
                    TextField("Start date (YYYY-MM-DD)", text: $order.timelineConfig.dateStart)
                    TextField("End date (YYYY-MM-DD)", text: $order.timelineConfig.dateEnd)
                    Stepper(value: $order.timelineConfig.dateIntervalDays, in: 1...30) {
                        HStack {
                            Text("Interval (days)")
                            Spacer()
                            Text("\(order.timelineConfig.dateIntervalDays)").foregroundStyle(.secondary)
                        }
                    }
                }
            case .custom:
                Section("Labels (top → bottom)") {
                    CustomLabelsEditor(order: $order)
                }
            case .weekday, .month:
                EmptyView()
            }
        }
        .navigationTitle("Timeline Configuration")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CustomLabelsEditor: View {
    @Binding var order: EventOrder

    var body: some View {
        InsertRow { insertLabel(at: 0) }
        ForEach(order.timelineConfig.customLabels.indices, id: \.self) { index in
            HStack {
                TextField("Label", text: Binding(
                    get: { order.timelineConfig.customLabels[index] },
                    set: { order.timelineConfig.customLabels[index] = $0 }
                ))
                Button(role: .destructive) { removeLabel(at: index) } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }
            InsertRow { insertLabel(at: index + 1) }
        }
    }

    /// Mirrors `insertCustomLabel` (app.js:1186-1204).
    private func insertLabel(at index: Int) {
        TimelineGeometry.ensureGapSizes(&order)
        let newGap = order.timelineConfig.pixelsPerMarker
        let cutY = TimelineGeometry.markerY(index, order: order)
        order.timelineConfig.customLabels.insert("New", at: index)
        order.timelineConfig.gapSizes?.insert(newGap, at: index)
        TimelineGeometry.shiftEvents(in: &order, atOrBelow: cutY, by: newGap)
        TimelineGeometry.recalcAllEventTimes(&order)
    }

    /// Mirrors `removeCustomLabel` (app.js:1205-1226).
    private func removeLabel(at index: Int) {
        guard order.timelineConfig.customLabels.count > 1 else { return }
        TimelineGeometry.ensureGapSizes(&order)
        let removedGap = order.timelineConfig.gapSizes?[index] ?? order.timelineConfig.pixelsPerMarker
        let slotStart = TimelineGeometry.markerY(index, order: order)
        let slotEnd = slotStart + removedGap
        order.timelineConfig.customLabels.remove(at: index)
        order.timelineConfig.gapSizes?.remove(at: index)
        for colIndex in order.characterColumns.indices {
            for evtIndex in order.characterColumns[colIndex].events.indices {
                let y = order.characterColumns[colIndex].events[evtIndex].yPos
                if y >= slotEnd {
                    order.characterColumns[colIndex].events[evtIndex].yPos = y - removedGap
                } else if y >= slotStart {
                    order.characterColumns[colIndex].events[evtIndex].yPos = slotStart
                }
            }
        }
        TimelineGeometry.recalcAllEventTimes(&order)
    }
}

private struct InsertRow: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("Insert here", systemImage: "plus.circle")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}
