import SwiftUI

/// Port of app.js's location drawing constants and geometry helpers
/// (`AREA_DEFAULTS`/`ICON_DEFAULTS` app.js:11-23, `niceInterval` app.js:36-40,
/// `locCanvasW`/`locCanvasH` app.js:1329-1330, `locXTicks`/`locYTicks`
/// app.js:414-424). Pure data + math, no view dependency — the same split
/// `TimelineMath` uses, and unit-testable for the same reason.
enum LocationTools {

    /// The drawing tool currently armed. app.js keeps this as a bare string
    /// (`drawTool`) and re-derives its kind by membership tests against
    /// `ALL_ICONS`/`ALL_AREAS`; modelling it as an enum makes the three
    /// distinct interaction modes (drag-to-draw, tap-to-place, tap-to-outline)
    /// explicit instead of implied.
    enum Tool: Hashable, Identifiable {
        case select
        case shape(Shape)
        case icon(Icon)
        case area(Area)

        var id: String { rawValue }

        /// The string persisted as `LocationObject.type` — must stay
        /// byte-identical to app.js's, since the Mac app reads these files.
        var rawValue: String {
            switch self {
            case .select: return "select"
            case .shape(let s): return s.rawValue
            case .icon(let i): return i.rawValue
            case .area(let a): return a.rawValue
            }
        }

        /// SF Symbol for the tool button. app.js uses emoji here (its
        /// `dt-icon` ternary chain, app.js:2385-2392), but several of those
        /// glyphs have no font coverage on iOS and render as `?` boxes —
        /// SF Symbols are the native equivalent and always resolve.
        var symbol: String {
            switch self {
            case .select: return "cursorarrow"
            case .shape(let s): return s.symbol
            case .icon(let i): return i.symbol
            case .area(let a): return a.symbol
            }
        }

        var label: String {
            switch self {
            case .select: return "Select"
            case .shape(let s): return s.rawValue.capitalized
            case .icon(let i): return i.rawValue.capitalized
            case .area(let a): return a.rawValue.capitalized
            }
        }
    }

    /// Drag-to-draw primitives (app.js:1333, 1343-1350).
    enum Shape: String, CaseIterable, Hashable {
        case rectangle, ellipse, circle

        var symbol: String {
            switch self {
            case .rectangle: return "rectangle"
            case .ellipse: return "oval"
            case .circle: return "circle.fill"
            }
        }

        /// app.js:1348 — circles get a distinct default fill from rect/ellipse.
        var defaultColor: String { self == .circle ? "#bdc3c7" : "#dfe6e9" }
        var defaultStroke: String { "#636e72" }
    }

    /// Tap-to-place icons — keys and colors from `ICON_DEFAULTS` (app.js:17-21).
    enum Icon: String, CaseIterable, Hashable {
        case tree, house, castle, car, bed, table, door, shop, building, fountain

        var defaultColor: String {
            switch self {
            case .tree: return "#27ae60"
            case .house: return "#e74c3c"
            case .castle: return "#7f8c8d"
            case .car: return "#3498db"
            case .bed: return "#9b59b6"
            case .table: return "#8B4513"
            case .door: return "#d35400"
            case .shop: return "#e67e22"
            case .building: return "#34495e"
            case .fountain: return "#1abc9c"
            }
        }

        var symbol: String {
            switch self {
            case .tree: return "tree"
            case .house: return "house"
            case .castle: return "building.columns"
            case .car: return "car"
            case .bed: return "bed.double"
            case .table: return "table.furniture"
            case .door: return "door.left.hand.closed"
            case .shop: return "storefront"
            case .building: return "building.2"
            case .fountain: return "drop.circle"
            }
        }
    }

    /// Tap-to-outline polygon areas — from `AREA_DEFAULTS` (app.js:11-16).
    /// `road` is the odd one out: rendered as a thick open polyline rather
    /// than a filled polygon (app.js:2540-2545).
    enum Area: String, CaseIterable, Hashable {
        case lake, road, sand, garden

        var defaultColor: String {
            switch self {
            case .lake: return "rgba(52,152,219,0.45)"
            case .road: return "#95a5a6"
            case .sand: return "rgba(241,196,15,0.40)"
            case .garden: return "rgba(46,204,113,0.40)"
            }
        }

        var defaultStroke: String {
            switch self {
            case .lake: return "#2980b9"
            case .road: return "#95a5a6"
            case .sand: return "#f1c40f"
            case .garden: return "#27ae60"
            }
        }

        var defaultStrokeWidth: Double { self == .road ? 14 : 2 }

        /// Roads are strokes along a path, so two points is already a valid
        /// road; filled areas need three to enclose anything.
        var minimumPoints: Int { self == .road ? 2 : 3 }

        var symbol: String {
            switch self {
            case .lake: return "drop.fill"
            case .road: return "road.lanes"
            case .sand: return "beach.umbrella"
            case .garden: return "leaf.fill"
            }
        }
    }

    /// Tool palette order, matching app.js's button list (app.js:2383-2384).
    static let allTools: [Tool] =
        [.select]
        + Shape.allCases.map { .shape($0) }
        + Icon.allCases.map { .icon($0) }
        + Area.allCases.map { .area($0) }

    /// Classifies a persisted `LocationObject.type` back into a tool, so
    /// rendering and the properties panel can branch on kind the way app.js's
    /// `ALL_ICONS.includes(...)` tests do.
    static func tool(forType type: String) -> Tool? {
        if let shape = Shape(rawValue: type) { return .shape(shape) }
        if let icon = Icon(rawValue: type) { return .icon(icon) }
        if let area = Area(rawValue: type) { return .area(area) }
        return nil
    }

    // MARK: - Geometry

    /// Verbatim port of `niceInterval` (app.js:36-40) — picks a round grid
    /// step of roughly range/8.
    static func niceInterval(_ range: Double) -> Double {
        guard range > 0 else { return 1 }
        let rough = range / 8
        let magnitude = pow(10, floor(log10(rough)))
        let r = rough / magnitude
        if r <= 1.5 { return magnitude }
        if r <= 3.5 { return 2 * magnitude }
        if r <= 7.5 { return 5 * magnitude }
        return 10 * magnitude
    }

    /// `locCanvasW`/`locCanvasH` (app.js:1329-1330): 8pt per unit, with a
    /// floor so a tiny location still gets a usable drawing surface.
    static func canvasSize(for location: Location) -> CGSize {
        CGSize(
            width: max(600, location.width * 8),
            height: max(400, location.height * 8)
        )
    }

    struct Tick: Identifiable {
        var id: Double { value }
        let value: Double
        let position: Double
    }

    /// `locXTicks`/`locYTicks` (app.js:414-424). `extent` is the location's
    /// size in its own unit; `pixels` the canvas dimension it maps onto.
    static func ticks(extent: Double, pixels: Double) -> [Tick] {
        guard extent > 0 else { return [] }
        let interval = niceInterval(extent)
        let scale = pixels / extent
        var ticks: [Tick] = []
        var value: Double = 0
        // Step by index rather than accumulating, to avoid float drift
        // compounding across a long axis.
        var index = 0
        while value <= extent + 1e-9 {
            ticks.append(Tick(value: value, position: value * scale))
            index += 1
            value = Double(index) * interval
        }
        return ticks
    }

    /// Formats a tick label without a trailing `.0` on whole numbers, the way
    /// JS's default number-to-string does.
    static func tickLabel(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e9
            ? String(Int(value))
            : String(format: "%g", value)
    }
}
