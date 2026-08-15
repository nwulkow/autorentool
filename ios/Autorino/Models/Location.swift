import Foundation

/// Mirrors `locations` (app.js:67-70, 1313-1330).
struct Location: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var description: String
    var width: Double
    var height: Double
    var unit: String
    var objects: [LocationObject]

    init(id: String = IDGenerator.uid(), name: String = "", description: String = "", width: Double = 10, height: Double = 10, unit: String = "m", objects: [LocationObject] = []) {
        self.id = id
        self.name = name
        self.description = description
        self.width = width
        self.height = height
        self.unit = unit
        self.objects = objects
    }
}

/// A single drawable object on the location map: a shape (rectangle/
/// ellipse/circle), an icon, or a free-drawn area (polygon via `points`).
/// Mirrors the object literals built in app.js's `onLocMU`/`onLocClick`/
/// `finishArea` (app.js:1339-1379).
struct LocationObject: Codable, Identifiable, Hashable {
    var id: String
    /// "rectangle" | "ellipse" | "circle" | an icon name | an area name (e.g. "lake")
    var type: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var color: String
    var stroke: String
    var strokeWidth: Double
    var name: String
    var scale: Double
    /// Polygon points for freehand areas, `[[x,y], ...]`. Empty for shapes/icons.
    var points: [[Double]]

    init(id: String = IDGenerator.uid(), type: String, x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0, color: String = "#dfe6e9", stroke: String = "#636e72", strokeWidth: Double = 2, name: String = "", scale: Double = 1, points: [[Double]] = []) {
        self.id = id
        self.type = type
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.color = color
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.name = name
        self.scale = scale
        self.points = points
    }
}
