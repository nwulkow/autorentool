import Foundation

/// The LLM side of the location map: describing a map as text (so the model
/// can reason about it — the assistant chat's context) and turning a
/// structured answer back into `LocationObject`s.
///
/// Text, not a screenshot: the stored objects are exact (type, name,
/// position, size), a description costs a few hundred tokens against an
/// image's thousand-plus, and the same coordinate system then works in both
/// directions — the model reads positions in metres and answers in metres.
///
/// iOS only. The web app has no location assistant; the objects this
/// produces are ordinary `LocationObject`s, so it renders them all the same.
enum LocationGeneration {

    // MARK: - Map → text

    /// Positions are given in the location's own unit, origin top-left —
    /// the canvas-point coordinates objects are stored in are meaningless
    /// to a model (and unevenly stretched, see `pointsPerUnit`).
    static func describe(_ location: Location) -> String {
        let scale = LocationTools.pointsPerUnit(for: location)
        let unit = location.unit
        func u(_ value: Double, _ axisScale: Double) -> String { format(value / axisScale) }

        var lines = ["Location map: \(location.name.isEmpty ? "(unnamed)" : location.name)"]
        if !location.description.isEmpty {
            lines.append("Description: \(location.description)")
        }
        lines.append("Size: \(format(location.width)) × \(format(location.height)) \(unit). Coordinates in \(unit), origin at the top-left corner, x to the right (east), y downwards (south).")

        if location.objects.isEmpty {
            lines.append("The map is empty.")
            return lines.joined(separator: "\n")
        }
        lines.append("Objects (drawn bottom to top):")
        for object in location.objects {
            let name = object.name.isEmpty ? "" : " \"\(object.name)\""
            let color = " color \(object.color)"
            switch LocationTools.tool(forType: object.type) {
            case .area(let area):
                let points = object.points.filter { $0.count >= 2 }
                    .map { "(\(u($0[0], scale.width)), \(u($0[1], scale.height)))" }
                    .joined(separator: " ")
                let shape = area == .road ? "path through" : "outline"
                lines.append("- \(object.type)\(name): \(shape) \(points);\(color)")
            case .icon:
                lines.append("- \(object.type)\(name): at (\(u(object.x, scale.width)), \(u(object.y, scale.height)));\(color)")
            case .shape:
                lines.append("- \(object.type)\(name): centre (\(u(object.x, scale.width)), \(u(object.y, scale.height))), \(u(object.width, scale.width)) × \(u(object.height, scale.height)) \(unit);\(color)")
            case .select, .none:
                lines.append("- \(object.type)\(name)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func format(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return LocationTools.tickLabel(rounded)
    }

    // MARK: - Request

    /// System instruction for `LLMService.locationObjects`.
    static func instruction(for location: Location) -> String {
        let icons = LocationTools.Icon.allCases.map(\.rawValue).joined(separator: ", ")
        let areas = LocationTools.Area.allCases.map(\.rawValue).joined(separator: ", ")
        return """
        You lay out objects on a top-down map of a place in a novel. The writer describes what they
        want; you return objects to ADD to the map. Never repeat objects that are already on it.

        Coordinates are in \(location.unit), origin at the top-left corner, x to the right, y
        downwards. The map is \(format(location.width)) × \(format(location.height)) \(location.unit);
        keep everything inside it. Use realistic real-world sizes and plausible arrangement (roads
        connect things, a fountain sits in a square, beds are inside rooms).

        Object types:
        - rectangle, ellipse, circle: buildings, rooms, walls, fields, squares. Give x, y as the
          CENTRE and width, height as the size. Leave points empty.
        - icons (\(icons)): a symbol at x, y. width and height are ignored — set them to 0.
          Leave points empty.
        - areas (\(areas)): give an outline in points (at least 3; a road needs at least 2 and is a
          path, not a closed outline). Set x, y, width, height to 0.

        name: a short label in the language the writer uses, or empty. Name things the story
        would refer to by name; leave generic filler (the fifth tree) unnamed.
        color: "#rrggbb", or empty for the default look of that type.

        If chapter summaries are given, they are the story so far: where they mention this place,
        follow them — put what the chapters describe where they describe it, use the names they
        use, and never contradict them. Where they say nothing, invent freely but plausibly.
        note: one or two sentences for the writer on what you placed and why, in their language.
        """
    }

    /// The user turn: the book (if sent) as background, then the map as it
    /// is, then what to add — the request nearest the question, as in the chat.
    static func prompt(for location: Location, request: String, bookContext: String = "") -> String {
        let book = bookContext.isEmpty ? "" : bookContext + "\n\n"
        return "\(book)\(describe(location))\n\nWhat to add:\n\(request)"
    }

    // MARK: - Answer → objects

    /// Converts the model's objects into canvas-space `LocationObject`s.
    /// Unknown types and degenerate outlines are dropped rather than guessed
    /// at; everything is clamped into the map. Each object takes the look of
    /// the last one of its type already on the map (see
    /// `LocationTools.styleTemplate`), unless the model chose a color.
    static func objects(from payload: LocationGenerationPayload, for location: Location) -> [LocationObject] {
        let scale = LocationTools.pointsPerUnit(for: location)
        let size = LocationTools.canvasSize(for: location)
        func px(_ x: Double) -> Double { min(max(x * scale.width, 0), size.width) }
        func py(_ y: Double) -> Double { min(max(y * scale.height, 0), size.height) }

        var result: [LocationObject] = []
        for item in payload.objects {
            guard let tool = LocationTools.tool(forType: item.type) else { continue }
            let template = LocationTools.styleTemplate(forType: item.type, in: location)
            var object: LocationObject
            switch tool {
            case .shape(let shape):
                var width = max(item.width ?? 0, 0) * scale.width
                var height = max(item.height ?? 0, 0) * scale.height
                if width <= 0 && height <= 0 { width = 4 * scale.width; height = 4 * scale.height }
                if shape == .circle { width = max(width, height); height = width }
                object = LocationTools.adoptingStyle(
                    LocationObject(type: shape.rawValue, x: px(item.x ?? 0), y: py(item.y ?? 0),
                                   width: width, height: height,
                                   color: shape.defaultColor, stroke: shape.defaultStroke, strokeWidth: 2),
                    from: template)
                if let color = hexColor(item.color) { object.color = color }

            case .icon(let icon):
                object = LocationTools.adoptingStyle(
                    LocationObject(type: icon.rawValue, x: px(item.x ?? 0), y: py(item.y ?? 0),
                                   width: LocationIconRenderer.nominalSize.width,
                                   height: LocationIconRenderer.nominalSize.height,
                                   color: icon.defaultColor, stroke: "#333", strokeWidth: 1),
                    from: template)
                if let color = hexColor(item.color) { object.color = color }

            case .area(let area):
                let points = (item.points ?? []).map { [px($0.x), py($0.y)] }
                guard points.count >= area.minimumPoints else { continue }
                object = LocationTools.adoptingStyle(
                    LocationObject(type: area.rawValue, color: area.defaultColor, stroke: area.defaultStroke,
                                   strokeWidth: area.defaultStrokeWidth, points: points),
                    from: template)
                // Area fills are translucent on purpose (a lake over a
                // field); a model's opaque "#rrggbb" keeps the fill's alpha.
                if let color = hexColor(item.color), var components = CSSColor.parse(color) {
                    components.alpha = CSSColor.parse(object.color)?.alpha ?? 1
                    object.color = CSSColor.string(from: components)
                }

            case .select:
                continue
            }
            object.name = (item.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(object)
        }
        return result
    }

    private static func hexColor(_ string: String?) -> String? {
        guard let string = string?.trimmingCharacters(in: .whitespaces).lowercased(),
              string.range(of: #"^#[0-9a-f]{6}$"#, options: .regularExpression) != nil else { return nil }
        return string
    }
}

/// What `LLMService.locationObjects` returns. Every field optional and
/// decoded leniently: the schema asks for all of them, but one malformed
/// object should cost that object, not the whole answer.
struct LocationGenerationPayload: Decodable {
    struct Point: Decodable {
        var x: Double
        var y: Double
    }

    struct Item: Decodable {
        var type: String
        var name: String?
        var x: Double?
        var y: Double?
        var width: Double?
        var height: Double?
        var color: String?
        var points: [Point]?
    }

    var objects: [Item]
    var note: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        objects = (try? container.decodeIfPresent([LossyItem].self, forKey: .objects))?.compactMap(\.item) ?? []
        note = (try? container.decodeIfPresent(String.self, forKey: .note)) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case objects, note }

    private struct LossyItem: Decodable {
        let item: Item?
        init(from decoder: Decoder) throws { item = try? Item(from: decoder) }
    }

    static var geminiSchema: [String: Any] {
        let types = LocationTools.Shape.allCases.map(\.rawValue)
            + LocationTools.Icon.allCases.map(\.rawValue)
            + LocationTools.Area.allCases.map(\.rawValue)
        let itemKeys = ["type", "name", "x", "y", "width", "height", "color", "points"]
        return [
            "type": "OBJECT",
            "properties": [
                "objects": [
                    "type": "ARRAY",
                    "items": [
                        "type": "OBJECT",
                        "properties": [
                            "type": ["type": "STRING", "enum": types],
                            "name": ["type": "STRING"],
                            "x": ["type": "NUMBER"],
                            "y": ["type": "NUMBER"],
                            "width": ["type": "NUMBER"],
                            "height": ["type": "NUMBER"],
                            "color": ["type": "STRING"],
                            "points": [
                                "type": "ARRAY",
                                "items": [
                                    "type": "OBJECT",
                                    "properties": ["x": ["type": "NUMBER"], "y": ["type": "NUMBER"]],
                                    "required": ["x", "y"],
                                    "propertyOrdering": ["x", "y"],
                                ],
                            ],
                        ],
                        "required": itemKeys,
                        "propertyOrdering": itemKeys,
                    ],
                ],
                "note": ["type": "STRING"],
            ],
            "required": ["objects", "note"],
            "propertyOrdering": ["objects", "note"],
        ]
    }
}
