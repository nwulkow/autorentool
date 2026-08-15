import Foundation

/// Mirrors `event_orders[].timeline_config` (app.js:61, defaults at
/// app.js:101, field names read throughout `generateMarkers`/`timeFromY`,
/// app.js:118-184). All fields are optional because each timeline mode
/// only uses a subset — same as the loosely-typed JS object.
struct TimelineConfig: Codable, Hashable {
    enum Mode: String, Codable, CaseIterable {
        case clock, weekday, week, month, date, custom
    }

    var mode: Mode = .custom
    var pixelsPerMarker: Double = 80
    var customLabels: [String] = ["Start", "Middle", "End"]

    // clock mode
    var clockStart: String = "08:00"
    var clockEnd: String = "20:00"
    var clockIntervalMin: Int = 60

    // week mode
    var weekStart: Int = 1
    var weekEnd: Int = 8

    // date mode
    var dateStart: String = "2026-01-01"
    var dateEnd: String = "2026-01-31"
    var dateIntervalDays: Int = 1

    /// Per-marker gap height in points, overriding uniform `pixelsPerMarker`
    /// spacing when present and matching the marker count.
    var gapSizes: [Double]? = nil

    enum CodingKeys: String, CodingKey {
        case mode
        case pixelsPerMarker = "pixels_per_marker"
        case customLabels = "custom_labels"
        case clockStart = "clock_start"
        case clockEnd = "clock_end"
        case clockIntervalMin = "clock_interval_min"
        case weekStart = "week_start"
        case weekEnd = "week_end"
        case dateStart = "date_start"
        case dateEnd = "date_end"
        case dateIntervalDays = "date_interval_days"
        case gapSizes = "gap_sizes"
    }

    init() {}

    /// Custom decode: real `timeline_config` objects only ever contain the
    /// keys relevant to their current `mode` (app.js only writes
    /// `clock_start`/etc. once the user touches that mode's controls — the
    /// default literal is just `{mode, pixels_per_marker, custom_labels}`,
    /// classes.py:78-82). The synthesized decoder would `throw` on those
    /// files since it treats every non-Optional property as required, so
    /// every field here falls back to its default via `decodeIfPresent`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .custom
        pixelsPerMarker = try c.decodeIfPresent(Double.self, forKey: .pixelsPerMarker) ?? 80
        customLabels = try c.decodeIfPresent([String].self, forKey: .customLabels) ?? ["Start", "Middle", "End"]
        clockStart = try c.decodeIfPresent(String.self, forKey: .clockStart) ?? "08:00"
        clockEnd = try c.decodeIfPresent(String.self, forKey: .clockEnd) ?? "20:00"
        clockIntervalMin = try c.decodeIfPresent(Int.self, forKey: .clockIntervalMin) ?? 60
        weekStart = try c.decodeIfPresent(Int.self, forKey: .weekStart) ?? 1
        weekEnd = try c.decodeIfPresent(Int.self, forKey: .weekEnd) ?? 8
        dateStart = try c.decodeIfPresent(String.self, forKey: .dateStart) ?? "2026-01-01"
        dateEnd = try c.decodeIfPresent(String.self, forKey: .dateEnd) ?? "2026-01-31"
        dateIntervalDays = try c.decodeIfPresent(Int.self, forKey: .dateIntervalDays) ?? 1
        gapSizes = try c.decodeIfPresent([Double].self, forKey: .gapSizes)
    }
}

/// Mirrors `character_columns[].events[]` (app.js:64).
struct Event: Codable, Identifiable, Hashable {
    var id: String
    var description: String
    var yPos: Double
    var height: Double
    var time: String
    var locationId: String?

    enum CodingKeys: String, CodingKey {
        case id, description
        case yPos = "y_pos"
        case height, time
        case locationId = "location_id"
    }

    init(id: String = IDGenerator.uid(), description: String = "", yPos: Double = 0, height: Double = 50, time: String = "", locationId: String? = nil) {
        self.id = id
        self.description = description
        self.yPos = yPos
        self.height = height
        self.time = time
        self.locationId = locationId
    }
}

/// Mirrors `event_orders[].character_columns[]` (app.js:62-65). `characterId`
/// is `nil` for the "General" column — real book JSON serializes it as
/// `character_id: null` (app.js:63, `col.characterId` starts out `null`
/// from `addGeneralColumn`, app.js:1099-1103) — so this has to stay
/// optional, not default to `""`, or decoding any book with a General
/// column throws.
///
/// `EventOrder` only ever allows one General column at a time
/// (`addGeneralColumn` is a no-op if one already exists, app.js:1100-1101,
/// ported the same way in `TimelineView`), so `characterId ?? "general"` is
/// a safe, stable `Identifiable` id — no synthesized-per-instance UUID
/// needed, and two decodes of the same JSON produce equal values.
struct CharacterColumn: Codable, Identifiable, Hashable {
    var characterId: String?
    var events: [Event]

    var id: String { characterId ?? "general" }

    enum CodingKeys: String, CodingKey {
        case characterId = "character_id"
        case events
    }

    init(characterId: String? = nil, events: [Event] = []) {
        self.characterId = characterId
        self.events = events
    }
}

/// Mirrors `event_orders[]` (app.js:60-66).
struct EventOrder: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var timelineConfig: TimelineConfig
    var characterColumns: [CharacterColumn]

    enum CodingKeys: String, CodingKey {
        case id, name
        case timelineConfig = "timeline_config"
        case characterColumns = "character_columns"
    }

    init(id: String = IDGenerator.uid(), name: String = "Event Order", timelineConfig: TimelineConfig = TimelineConfig(), characterColumns: [CharacterColumn] = []) {
        self.id = id
        self.name = name
        self.timelineConfig = timelineConfig
        self.characterColumns = characterColumns
    }
}

// MARK: - Timeline marker generation
// Pure ports of app.js's generateMarkers/genClockMarkers/genDateMarkers/
// timeFromY (app.js:118-184). Kept dependency-free so they're usable (and
// unit-testable) ahead of the EventOrder *view* landing in a later phase.

struct TimelineMarker: Hashable {
    var label: String
    var index: Int
    /// Only set for clock-mode markers; used to interpolate precise times.
    var totalMin: Int? = nil
}

enum TimelineMath {
    static func generateMarkers(_ cfg: TimelineConfig) -> [TimelineMarker] {
        switch cfg.mode {
        case .clock: return clockMarkers(cfg)
        case .weekday:
            return ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].enumerated().map { TimelineMarker(label: $1, index: $0) }
        case .week:
            let s = cfg.weekStart, e = cfg.weekEnd
            guard e >= s else { return [] }
            return (0...(e - s)).map { TimelineMarker(label: "Week \(s + $0)", index: $0) }
        case .month:
            return ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"].enumerated().map { TimelineMarker(label: $1, index: $0) }
        case .date:
            return dateMarkers(cfg)
        case .custom:
            let labels = cfg.customLabels.isEmpty ? ["Start", "Middle", "End"] : cfg.customLabels
            return labels.enumerated().map { TimelineMarker(label: $1, index: $0) }
        }
    }

    private static func clockMarkers(_ cfg: TimelineConfig) -> [TimelineMarker] {
        func parse(_ s: String) -> (Int, Int) {
            let parts = s.split(separator: ":").compactMap { Int($0) }
            return (parts.first ?? 0, parts.count > 1 ? parts[1] : 0)
        }
        let (sh, sm) = parse(cfg.clockStart)
        let (eh, em) = parse(cfg.clockEnd)
        let interval = max(cfg.clockIntervalMin, 1)
        var marks: [TimelineMarker] = []
        var m = sh * 60 + sm
        let end = eh * 60 + em
        while m <= end {
            let h = m / 60, mn = m % 60
            marks.append(TimelineMarker(label: String(format: "%02d:%02d", h, mn), index: marks.count, totalMin: m))
            m += interval
        }
        return marks
    }

    private static func dateMarkers(_ cfg: TimelineConfig) -> [TimelineMarker] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        guard let start = formatter.date(from: cfg.dateStart), let end = formatter.date(from: cfg.dateEnd) else { return [] }
        let step = max(cfg.dateIntervalDays, 1)
        let display = DateFormatter()
        display.dateFormat = "MMM d"
        display.locale = Locale(identifier: "en_US")
        var marks: [TimelineMarker] = []
        var cur = start
        while cur <= end {
            marks.append(TimelineMarker(label: display.string(from: cur), index: marks.count))
            cur = Calendar.current.date(byAdding: .day, value: step, to: cur) ?? end.addingTimeInterval(1)
        }
        return marks
    }

    /// Inverse of marker layout: given a y position on the timeline, return
    /// the label (or interpolated clock time) at that height.
    static func timeFromY(_ yPos: Double, markers: [TimelineMarker], cfg: TimelineConfig) -> String {
        guard !markers.isEmpty else { return "" }
        let topPad: Double = 16
        let y = max(0, yPos - topPad)

        if let gs = cfg.gapSizes, gs.count == markers.count {
            var cumY: Double = 0
            for i in 0..<markers.count {
                let gapH = i < gs.count ? gs[i] : cfg.pixelsPerMarker
                if y <= cumY + gapH || i == markers.count - 1 {
                    if cfg.mode == .clock, let m0 = markers[0].totalMin, i + 1 < markers.count,
                       let mi = markers[i].totalMin, let mi1 = markers[i + 1].totalMin {
                        _ = m0
                        let frac = gapH > 0 ? (y - cumY) / gapH : 0
                        let m = Int((Double(mi) + frac * Double(mi1 - mi)).rounded())
                        return String(format: "%02d:%02d", m / 60, m % 60)
                    }
                    return markers[i].label
                }
                cumY += gapH
            }
            return markers[markers.count - 1].label
        }

        let ppm = cfg.pixelsPerMarker > 0 ? cfg.pixelsPerMarker : 80
        let idx = y / ppm
        if cfg.mode == .clock, markers[0].totalMin != nil {
            let lo = Int(idx.rounded(.down)), hi = Int(idx.rounded(.up))
            let frac = idx - Double(lo)
            if lo >= markers.count { return markers[markers.count - 1].label }
            if hi >= markers.count || lo == hi { return markers[lo].label }
            let mlo = markers[lo].totalMin ?? 0, mhi = markers[hi].totalMin ?? 0
            let m = Int((Double(mlo) + frac * Double(mhi - mlo)).rounded())
            return String(format: "%02d:%02d", m / 60, m % 60)
        }
        let zone = min(max(Int(idx.rounded(.down)), 0), markers.count - 1)
        return markers[zone].label
    }
}
