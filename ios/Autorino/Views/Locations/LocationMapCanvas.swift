import SwiftUI

/// The drawing surface itself: grid, rulers, all objects, and the in-progress
/// preview — one `Canvas` pass, mirroring app.js's single `<svg ref="locSvg">`
/// (app.js:2415-2566).
///
/// Interaction is split by tool, matching app.js's three input paths but
/// adapted to touch:
/// - **shapes** — drag to rubber-band a rect/ellipse/circle (app.js
///   `onLocMD`/`onLocMU`, mousedown→mouseup);
/// - **icons** — tap to drop at that point (`onLocClick`, app.js:1355-1361);
/// - **areas** — tap to append a polygon point (`onLocClick`, app.js:1362-1368).
///   app.js closes the polygon on double-click or a tap near the first point;
///   both are unreliable under a fingertip, so this exposes an explicit
///   **Finish** button instead (see `LocationEditorView`).
/// - **select** — drag an existing object to move it (`onObjMD`, app.js:1381-1393).
struct LocationMapCanvas: View {
    @Binding var location: Location
    let tool: LocationTools.Tool
    @Binding var selectedObjectId: String?
    @Binding var draftPoints: [[Double]]

    /// Rubber-band state for shape tools, the analogue of app.js's
    /// `drawStart`/`isDrawingShape`/`cursorPos` trio.
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    /// Set when a drag began on top of an existing object in select mode;
    /// holds that object's pre-drag geometry so the move is computed from the
    /// gesture's total translation rather than accumulated deltas.
    @State private var movingObject: (id: String, x: Double, y: Double, points: [[Double]])?

    private var canvasSize: CGSize { LocationTools.canvasSize(for: location) }

    var body: some View {
        Canvas { context, size in
            drawGrid(&context, size: size)
            drawRulers(&context, size: size)
            for object in location.objects {
                draw(object, in: &context)
            }
            drawPreview(&context)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .background(Color(uiColor: .systemBackground))
        .contentShape(Rectangle())
        // Tap always applies (place an icon, add an area point, select), and
        // is spatial so the handler gets the point in canvas coordinates.
        .onTapGesture(coordinateSpace: .local) { point in handleTap(at: point) }
        // Drag gestures are attached only for the tool that needs one, rather
        // than always-on with a GestureMask: a leaf view has no subviews to
        // defer to, so masking one off still blocks the enclosing ScrollView.
        // With no drag attached, an empty-space drag reaches the ScrollView
        // and pans the map — which is how the map stays navigable at all.
        // app.js needs none of this: a mouse can hover, so it knows what is
        // under the pointer before the button ever goes down.
        .modifier(MapDragGestures(
            isShapeTool: isShapeTool,
            isSelectTool: tool == .select,
            shapeDrawGesture: shapeDrawGesture,
            moveGesture: moveGesture
        ))
    }

    private var isShapeTool: Bool {
        if case .shape = tool { return true }
        return false
    }

    /// Attaches at most one drag gesture, so that for the tools which don't
    /// need one (icons, areas) the view stays gesture-free and scrolling is
    /// handled entirely by the enclosing `ScrollView`.
    private struct MapDragGestures<Shape: Gesture, Move: Gesture>: ViewModifier {
        let isShapeTool: Bool
        let isSelectTool: Bool
        let shapeDrawGesture: Shape
        let moveGesture: Move

        func body(content: Content) -> some View {
            if isShapeTool {
                content.gesture(shapeDrawGesture)
            } else if isSelectTool {
                // Long-press-then-drag: a plain drag still scrolls the map.
                content.gesture(moveGesture)
            } else {
                content
            }
        }
    }

    // MARK: - Gestures

    /// Rubber-band a new shape — `onLocMD`/`onLocMU` (app.js:1331-1352).
    private var shapeDrawGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard isShapeTool else { return }
                if dragStart == nil { dragStart = value.startLocation }
                dragCurrent = value.location
            }
            .onEnded { value in
                defer {
                    dragStart = nil
                    dragCurrent = nil
                }
                guard case .shape(let shape) = tool, let start = dragStart else { return }
                commitShape(shape, from: start, to: value.location)
            }
    }

    /// Move an existing object — `onObjMD` (app.js:1381-1393). Gated behind a
    /// long press so a plain drag still scrolls the map; the press also
    /// selects, giving the user a visual confirmation of what they grabbed.
    private var moveGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.28)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard tool == .select else { return }
                switch value {
                case .first(true):
                    break
                case .second(true, let drag):
                    guard let drag else { return }
                    if movingObject == nil {
                        guard let hit = hitTest(drag.startLocation) else { return }
                        selectedObjectId = hit.id
                        movingObject = (hit.id, hit.x, hit.y, hit.points)
                    }
                    guard let moving = movingObject,
                          let index = location.objects.firstIndex(where: { $0.id == moving.id }) else { return }
                    let dx = drag.translation.width
                    let dy = drag.translation.height
                    if moving.points.isEmpty {
                        location.objects[index].x = moving.x + dx
                        location.objects[index].y = moving.y + dy
                    } else {
                        // Polygons carry their geometry in `points`, so they
                        // move by translating every vertex (app.js:1387).
                        location.objects[index].points = moving.points.map { [$0[0] + dx, $0[1] + dy] }
                    }
                default:
                    break
                }
            }
            .onEnded { _ in movingObject = nil }
    }

    /// `onLocClick` (app.js:1354-1369) — icons drop, areas accumulate points,
    /// select clears the selection when tapping empty space.
    private func handleTap(at point: CGPoint) {
        switch tool {
        case .icon(let icon):
            var object = LocationObject(
                type: icon.rawValue,
                x: point.x, y: point.y,
                width: LocationIconRenderer.nominalSize.width,
                height: LocationIconRenderer.nominalSize.height,
                color: icon.defaultColor,
                stroke: "#333",
                strokeWidth: 1
            )
            object.scale = 1
            location.objects.append(object)
            selectedObjectId = object.id

        case .area:
            draftPoints.append([point.x, point.y])

        case .select:
            selectedObjectId = hitTest(point)?.id

        case .shape:
            break
        }
    }

    /// `onLocMU` (app.js:1338-1352) — a drag under ~4pt is treated as a
    /// mis-tap and discarded rather than creating a degenerate shape.
    private func commitShape(_ shape: LocationTools.Shape, from start: CGPoint, to end: CGPoint) {
        let width = abs(end.x - start.x)
        let height = abs(end.y - start.y)
        guard width > 4 || height > 4 else { return }
        let centerX = min(start.x, end.x) + width / 2
        let centerY = min(start.y, end.y) + height / 2
        let object = LocationObject(
            type: shape.rawValue,
            x: centerX, y: centerY,
            width: shape == .circle ? max(width, height) : width,
            height: shape == .circle ? max(width, height) : height,
            color: shape.defaultColor,
            stroke: shape.defaultStroke,
            strokeWidth: 2
        )
        location.objects.append(object)
        selectedObjectId = object.id
    }

    /// Topmost-first hit test, so the object drawn last (visually on top) is
    /// the one a tap grabs — the same z-order SVG gives you for free.
    private func hitTest(_ point: CGPoint) -> LocationObject? {
        location.objects.reversed().first { object in
            guard let tool = LocationTools.tool(forType: object.type) else { return false }
            switch tool {
            case .area:
                return hitTestPolyline(object, point: point)
            case .icon:
                let half = LocationIconRenderer.nominalSize.width * max(object.scale, 0.2) / 2
                return abs(point.x - object.x) <= half && abs(point.y - object.y) <= half
            case .shape, .select:
                return abs(point.x - object.x) <= max(object.width, 12) / 2
                    && abs(point.y - object.y) <= max(object.height, 12) / 2
            }
        }
    }

    /// Areas are hit-tested against their path rather than a bounding box —
    /// a lake's box can cover most of the map while the lake itself doesn't.
    private func hitTestPolyline(_ object: LocationObject, point: CGPoint) -> Bool {
        let points = object.points.compactMap { $0.count >= 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        guard points.count >= 2 else { return false }
        if object.type == LocationTools.Area.road.rawValue {
            // Roads are open strokes: near any segment, within its width.
            let tolerance = max(object.strokeWidth, 12) / 2
            return zip(points, points.dropFirst()).contains { distance(from: point, toSegment: $0, $1) <= tolerance }
        }
        var path = Path()
        path.move(to: points[0])
        for p in points.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        return path.contains(point)
    }

    private func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    // MARK: - Rendering

    /// 40pt grid, matching the SVG `<pattern id="grid">` (app.js:2419-2422).
    /// The pattern fills the whole canvas, as in the web version — the canvas
    /// is sized from the location's own dimensions, so the two already agree.
    private func drawGrid(_ context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        var x: Double = 0
        while x <= size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += 40 }
        var y: Double = 0
        while y <= size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += 40 }
        context.stroke(path, with: .color(Color(red: 0.878, green: 0.863, blue: 0.831)), lineWidth: 0.5)
    }

    /// Unit rulers along the top and left edges (app.js:2433-2442), labelled
    /// in the location's own unit.
    private func drawRulers(_ context: inout GraphicsContext, size: CGSize) {
        let tickColor = Color(white: 0.47)
        for tick in LocationTools.ticks(extent: location.width, pixels: size.width) {
            var path = Path()
            path.move(to: CGPoint(x: tick.position, y: 0))
            path.addLine(to: CGPoint(x: tick.position, y: 6))
            context.stroke(path, with: .color(tickColor), lineWidth: 1)
            context.draw(
                Text(LocationTools.tickLabel(tick.value)).font(.system(size: 9)).foregroundStyle(tickColor),
                at: CGPoint(x: tick.position + 2, y: 12), anchor: .leading
            )
        }
        for tick in LocationTools.ticks(extent: location.height, pixels: size.height) {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: tick.position))
            path.addLine(to: CGPoint(x: 6, y: tick.position))
            context.stroke(path, with: .color(tickColor), lineWidth: 1)
            context.draw(
                Text(LocationTools.tickLabel(tick.value)).font(.system(size: 9)).foregroundStyle(tickColor),
                at: CGPoint(x: 9, y: tick.position + 2), anchor: .topLeading
            )
        }
        context.draw(
            Text(location.unit).font(.system(size: 9)).italic().foregroundStyle(Color(white: 0.67)),
            at: CGPoint(x: size.width - 4, y: size.height - 5), anchor: .bottomTrailing
        )
    }

    private func draw(_ object: LocationObject, in context: inout GraphicsContext) {
        let fill = CSSColor.color(object.color)
        let stroke = CSSColor.color(object.stroke)
        let isSelected = object.id == selectedObjectId

        switch LocationTools.tool(forType: object.type) {
        case .shape(let shape):
            let path = shapePath(shape, object)
            context.fill(path, with: .color(fill))
            context.stroke(path, with: .color(stroke), lineWidth: object.strokeWidth)
            if isSelected { strokeSelection(path, in: &context) }

        case .icon(let icon):
            var layer = context
            layer.translateBy(x: object.x, y: object.y)
            layer.scaleBy(x: max(object.scale, 0.2), y: max(object.scale, 0.2))
            LocationIconRenderer.draw(icon, in: &layer, color: fill, stroke: stroke)
            if isSelected {
                let half = LocationIconRenderer.nominalSize.width * max(object.scale, 0.2) / 2
                let box = Path(roundedRect: CGRect(
                    x: object.x - half, y: object.y - half,
                    width: half * 2, height: half * 2
                ), cornerRadius: 4)
                strokeSelection(box, in: &context)
            }

        case .area(let area):
            let points = object.points.compactMap { $0.count >= 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
            guard points.count >= area.minimumPoints else { break }
            var path = Path()
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            if area == .road {
                // Open polyline stroked at full width (app.js:2540-2545).
                context.stroke(path, with: .color(fill),
                               style: StrokeStyle(lineWidth: object.strokeWidth, lineCap: .round, lineJoin: .round))
            } else {
                path.closeSubpath()
                context.fill(path, with: .color(fill))
                context.stroke(path, with: .color(stroke), lineWidth: object.strokeWidth)
            }
            if isSelected { strokeSelection(path, in: &context) }

        case .select, .none:
            break
        }

        drawLabel(object, in: &context)
    }

    private func shapePath(_ shape: LocationTools.Shape, _ object: LocationObject) -> Path {
        switch shape {
        case .rectangle:
            return Path(CGRect(x: object.x - object.width / 2, y: object.y - object.height / 2,
                               width: object.width, height: object.height))
        case .ellipse:
            return Path(ellipseIn: CGRect(x: object.x - object.width / 2, y: object.y - object.height / 2,
                                          width: object.width, height: object.height))
        case .circle:
            let radius = object.width / 2
            return Path(ellipseIn: CGRect(x: object.x - radius, y: object.y - radius,
                                          width: radius * 2, height: radius * 2))
        }
    }

    private func strokeSelection(_ path: Path, in context: inout GraphicsContext) {
        context.stroke(path, with: .color(.accentColor),
                       style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
    }

    /// Name label, centered on the polygon's centroid or below a shape/icon —
    /// same placement rule as app.js:2549-2553.
    private func drawLabel(_ object: LocationObject, in context: inout GraphicsContext) {
        guard !object.name.isEmpty else { return }
        let position: CGPoint
        if !object.points.isEmpty {
            let valid = object.points.filter { $0.count >= 2 }
            guard !valid.isEmpty else { return }
            position = CGPoint(
                x: valid.reduce(0) { $0 + $1[0] } / Double(valid.count),
                y: valid.reduce(0) { $0 + $1[1] } / Double(valid.count)
            )
        } else {
            let height = object.height > 0 ? object.height : LocationIconRenderer.nominalSize.height
            position = CGPoint(x: object.x, y: object.y + height / 2 + 14)
        }
        // The SVG fakes an outline with paint-order:stroke; approximate it by
        // drawing the text four times offset, then once on top.
        let label = Text(object.name).font(.system(size: 11))
        for dx in [-1.0, 1.0] {
            for dy in [-1.0, 1.0] {
                context.draw(label.foregroundStyle(.white),
                             at: CGPoint(x: position.x + dx, y: position.y + dy), anchor: .center)
            }
        }
        context.draw(label.foregroundStyle(Color(white: 0.2)), at: position, anchor: .center)
    }

    /// The in-progress rubber band / polygon outline (app.js:2555-2566).
    private func drawPreview(_ context: inout GraphicsContext) {
        if case .shape(let shape) = tool, let start = dragStart, let current = dragCurrent {
            let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                              width: abs(current.x - start.x), height: abs(current.y - start.y))
            let path: Path
            switch shape {
            case .rectangle: path = Path(rect)
            case .ellipse:   path = Path(ellipseIn: rect)
            case .circle:
                let diameter = max(rect.width, rect.height)
                path = Path(ellipseIn: CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                                              width: diameter, height: diameter))
            }
            context.fill(path, with: .color(Color(red: 0.39, green: 0.39, blue: 0.78).opacity(0.2)))
            context.stroke(path, with: .color(Color(white: 0.4)), style: StrokeStyle(lineWidth: 1, dash: [4]))
        }

        guard !draftPoints.isEmpty else { return }
        let points = draftPoints.compactMap { $0.count >= 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        guard let first = points.first else { return }
        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        context.stroke(path, with: .color(Color(red: 0.29, green: 0.49, blue: 1.0)),
                       style: StrokeStyle(lineWidth: 2, dash: [5]))
        for point in points {
            context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)),
                         with: .color(Color(red: 0.29, green: 0.49, blue: 1.0)))
        }
    }
}
