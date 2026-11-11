import SwiftUI

/// The drawing surface itself: grid, rulers, all objects, and the in-progress
/// preview — one `Canvas` pass, mirroring app.js's single `<svg ref="locSvg">`
/// (app.js:2415-2566).
///
/// The map lives in its own coordinate space (the "canvas points" every
/// `LocationObject` is stored in, shared with the web app) and is shown
/// through a pan/zoom viewport: one finger pans, pinch zooms around the
/// fingers, two fingers pan. Touch input comes from `MapGestureView`.
///
/// What a touch does, by tool — adapted from app.js's three input paths:
/// - **tap** on an object selects it, whatever the tool (icon tools skip
///   areas and shapes, so a car can still be dropped into a lake or a room);
///   on empty map it drops an icon (`onLocClick`, app.js:1355-1361) or, with
///   an area tool, appends a polygon point (app.js:1362-1368). app.js closes
///   a polygon on double-click; here there is an explicit **Finish** button
///   (see `LocationEditorView`).
/// - **drag** on the selected object moves it at once (`onObjMD`,
///   app.js:1381-1393); with the select tool, dragging any icon or shape
///   grabs it. Areas must be tapped first, since they cover so much of a map
///   that grabbing them on contact would make the map impossible to pan.
///   With a shape tool a drag elsewhere rubber-bands a new shape
///   (`onLocMD`/`onLocMU`); otherwise it pans.
/// - **multi-select** (`multiSelect`): a tap adds or removes any object,
///   areas included; a drag on empty space draws a selection rectangle; a
///   drag on any selected object moves the whole selection. Two fingers
///   still pan.
/// - **long press** (half a second) then drag, with any tool: a selection
///   rectangle that replaces the selection (adds to it in multi-select).
///   Dragging any of several selected objects then moves them all.
struct LocationMapCanvas: View {
    @Binding var location: Location
    let tool: LocationTools.Tool
    @Binding var selection: Set<String>
    let multiSelect: Bool
    @Binding var draftPoints: [[Double]]

    /// Screen points per canvas point; 0 until the first layout fits the map.
    @State private var zoom: CGFloat = 0
    /// Where the map's origin sits in the view.
    @State private var offset: CGSize = .zero
    @State private var viewSize: CGSize = .zero
    /// Until the user pans or zooms, a layout change (the tab bar hiding as
    /// the screen is pushed, rotation) refits rather than leaving the map
    /// wherever the first, provisional size put it.
    @State private var hasMovedViewport = false
    @State private var drag: DragMode?
    /// Rubber-band state for shape tools and the selection rectangle (map
    /// coordinates), the analogue of app.js's `drawStart`/`isDrawingShape`/
    /// `cursorPos` trio.
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    private enum DragMode {
        case pan(startOffset: CGSize)
        /// Holds each moved object's pre-drag geometry, so the move is
        /// computed from the gesture's total translation and a cancelled drag
        /// can restore it.
        case move([String: Origin])
        case draw
        /// `adding`: union with the selection rather than replace it.
        case marquee(adding: Bool)
    }

    private struct Origin {
        let x: Double
        let y: Double
        let points: [[Double]]
    }

    private var canvasSize: CGSize { LocationTools.canvasSize(for: location) }

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, _ in
                guard zoom > 0 else { return }
                var map = context
                map.translateBy(x: offset.width, y: offset.height)
                map.scaleBy(x: zoom, y: zoom)
                let size = canvasSize
                map.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(uiColor: .systemBackground)))
                drawGrid(&map, size: size)
                drawRulers(&map, size: size)
                for object in location.objects {
                    draw(object, in: &map)
                }
                drawPreview(&map)
            }
            .overlay {
                MapGestureView(
                    onTap: handleTap,
                    onDragBegan: dragBegan,
                    onDragChanged: dragChanged,
                    onDragEnded: dragEnded,
                    onDragCancelled: dragCancelled,
                    onLongPressBegan: longPressBegan,
                    onPinch: pinch
                )
            }
            .overlay(alignment: .topTrailing) {
                Button { withAnimation(.easeOut(duration: 0.25)) { fit() } } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel(Text("Fit map"))
                .padding(10)
            }
            .onAppear {
                viewSize = proxy.size
                if zoom == 0 { fit() }
            }
            .onChange(of: proxy.size) { _, newSize in
                viewSize = newSize
                if hasMovedViewport { clampOffset() } else { fit() }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .clipped()
        // A new width/height in the editor changes the canvas size; refit so
        // the map isn't left half off screen.
        .onChange(of: canvasSize) { _, _ in fit() }
    }

    // MARK: - Viewport

    private var fitZoom: CGFloat {
        guard viewSize.width > 0, viewSize.height > 0 else { return 1 }
        return min((viewSize.width - 16) / canvasSize.width, (viewSize.height - 16) / canvasSize.height)
    }

    private var zoomRange: ClosedRange<CGFloat> {
        let fit = max(fitZoom, 0.01)
        return (fit * 0.5)...max(fit * 16, 6)
    }

    private func fit() {
        guard viewSize.width > 0 else { return }
        zoom = fitZoom
        offset = CGSize(
            width: (viewSize.width - canvasSize.width * zoom) / 2,
            height: (viewSize.height - canvasSize.height * zoom) / 2
        )
    }

    /// Keeps at least a strip of the map on screen, so it can't be flung
    /// out of reach.
    private func clampOffset() {
        guard zoom > 0 else { return }
        let margin: CGFloat = 60
        let mapWidth = canvasSize.width * zoom, mapHeight = canvasSize.height * zoom
        offset.width = min(max(offset.width, margin - mapWidth), viewSize.width - margin)
        offset.height = min(max(offset.height, margin - mapHeight), viewSize.height - margin)
    }

    private func toMap(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.width) / zoom, y: (point.y - offset.height) / zoom)
    }

    private func isOnMap(_ point: CGPoint) -> Bool {
        CGRect(origin: .zero, size: canvasSize).contains(point)
    }

    private func pinch(scale: CGFloat, translation: CGSize, centroid: CGPoint) {
        guard zoom > 0 else { return }
        hasMovedViewport = true
        let newZoom = min(max(zoom * scale, zoomRange.lowerBound), zoomRange.upperBound)
        let factor = newZoom / zoom
        // Zoom about the fingers: the map point under the centroid stays put.
        offset.width = centroid.x - (centroid.x - offset.width) * factor + translation.width
        offset.height = centroid.y - (centroid.y - offset.height) * factor + translation.height
        zoom = newZoom
        clampOffset()
    }

    // MARK: - Gestures

    private func handleTap(_ screenPoint: CGPoint) {
        guard zoom > 0 else { return }
        let point = toMap(screenPoint)
        if multiSelect {
            if let hit = hitTest(point) { selection.formSymmetricDifference([hit.id]) }
            return
        }
        switch tool {
        case .area:
            guard isOnMap(point) else { return }
            draftPoints.append([point.x, point.y])

        case .icon(let icon):
            if let hit = hitTest(point, where: { LocationTools.tool(forType: $0.type)?.isIcon == true }) {
                selection = [hit.id]
                return
            }
            guard isOnMap(point) else { return }
            let object = LocationTools.adoptingStyle(
                LocationObject(
                    type: icon.rawValue,
                    x: point.x, y: point.y,
                    width: LocationIconRenderer.nominalSize.width,
                    height: LocationIconRenderer.nominalSize.height,
                    color: icon.defaultColor,
                    stroke: "#333",
                    strokeWidth: 1
                ),
                from: LocationTools.styleTemplate(forType: icon.rawValue, in: location)
            )
            location.objects.append(object)
            selection = [object.id]

        case .select, .shape:
            selection = hitTest(point).map { [$0.id] } ?? []
        }
    }

    private func dragBegan(_ screenStart: CGPoint) {
        guard zoom > 0 else { return }
        let start = toMap(screenStart)
        let canMove = multiSelect || selection.count > 1 || !tool.isArea

        if canMove, hitTest(start, where: { selection.contains($0.id) }) != nil {
            drag = .move(origins(of: selection))
        } else if multiSelect {
            drag = .marquee(adding: true)
            dragStart = start
            dragCurrent = start
        } else if tool == .select, let hit = hitTest(start, where: { LocationTools.tool(forType: $0.type)?.isArea != true }) {
            selection = [hit.id]
            drag = .move(origins(of: [hit.id]))
        } else if case .shape = tool, isOnMap(start) {
            drag = .draw
            dragStart = start
            dragCurrent = start
        } else {
            drag = .pan(startOffset: offset)
            hasMovedViewport = true
        }
    }

    private func longPressBegan(_ screenPoint: CGPoint) {
        guard zoom > 0 else { return }
        let start = toMap(screenPoint)
        drag = .marquee(adding: multiSelect)
        dragStart = start
        dragCurrent = start
    }

    private func dragChanged(_ screenLocation: CGPoint, _ translation: CGSize) {
        switch drag {
        case .pan(let startOffset):
            offset = CGSize(width: startOffset.width + translation.width, height: startOffset.height + translation.height)
            clampOffset()
        case .move(let origins):
            let dx = translation.width / zoom, dy = translation.height / zoom
            for index in location.objects.indices {
                guard let origin = origins[location.objects[index].id] else { continue }
                if origin.points.isEmpty {
                    location.objects[index].x = origin.x + dx
                    location.objects[index].y = origin.y + dy
                } else {
                    // Polygons carry their geometry in `points`, so they move
                    // by translating every vertex (app.js:1387).
                    location.objects[index].points = origin.points.map { $0.count >= 2 ? [$0[0] + dx, $0[1] + dy] : $0 }
                }
            }
        case .draw, .marquee:
            dragCurrent = toMap(screenLocation)
        case nil:
            break
        }
    }

    private func dragEnded(_ velocity: CGSize) {
        defer { resetDrag() }
        switch drag {
        case .draw:
            guard case .shape(let shape) = tool, let start = dragStart, let end = dragCurrent else { return }
            commitShape(shape, from: start, to: end)
        case .marquee(let adding):
            guard let start = dragStart, let end = dragCurrent else { return }
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                              width: abs(end.x - start.x), height: abs(end.y - start.y))
            // By anchor point rather than overlap, so a small rectangle drawn
            // over a lake picks up the cars on it, not the lake.
            var picked = Set(location.objects.filter { rect.contains(anchor(of: $0)) }.map(\.id))
            // A long press released without dragging picks what is under it.
            if max(rect.width, rect.height) * zoom < 8 {
                picked = hitTest(start).map { [$0.id] } ?? []
            }
            if adding { selection.formUnion(picked) } else { selection = picked }
        case .pan:
            // A short glide, so flicking across a large map doesn't take
            // a dozen strokes.
            withAnimation(.easeOut(duration: 0.4)) {
                offset.width += velocity.width * 0.18
                offset.height += velocity.height * 0.18
                clampOffset()
            }
        case .move, nil:
            break
        }
    }

    private func dragCancelled() {
        if case .move(let origins) = drag {
            for index in location.objects.indices {
                guard let origin = origins[location.objects[index].id] else { continue }
                location.objects[index].x = origin.x
                location.objects[index].y = origin.y
                location.objects[index].points = origin.points
            }
        }
        resetDrag()
    }

    private func origins(of ids: Set<String>) -> [String: Origin] {
        var result: [String: Origin] = [:]
        for object in location.objects where ids.contains(object.id) {
            result[object.id] = Origin(x: object.x, y: object.y, points: object.points)
        }
        return result
    }

    /// Centre of a shape or icon, centroid of an area's points.
    private func anchor(of object: LocationObject) -> CGPoint {
        let valid = object.points.filter { $0.count >= 2 }
        guard !valid.isEmpty else { return CGPoint(x: object.x, y: object.y) }
        return CGPoint(
            x: valid.reduce(0) { $0 + $1[0] } / Double(valid.count),
            y: valid.reduce(0) { $0 + $1[1] } / Double(valid.count)
        )
    }

    private func resetDrag() {
        drag = nil
        dragStart = nil
        dragCurrent = nil
    }

    /// `onLocMU` (app.js:1338-1352) — a drag under ~4pt is treated as a
    /// mis-tap and discarded rather than creating a degenerate shape.
    private func commitShape(_ shape: LocationTools.Shape, from start: CGPoint, to end: CGPoint) {
        let width = abs(end.x - start.x)
        let height = abs(end.y - start.y)
        guard width > 4 || height > 4 else { return }
        let centerX = min(start.x, end.x) + width / 2
        let centerY = min(start.y, end.y) + height / 2
        let object = LocationTools.adoptingStyle(
            LocationObject(
                type: shape.rawValue,
                x: centerX, y: centerY,
                width: shape == .circle ? max(width, height) : width,
                height: shape == .circle ? max(width, height) : height,
                color: shape.defaultColor,
                stroke: shape.defaultStroke,
                strokeWidth: 2
            ),
            from: LocationTools.styleTemplate(forType: shape.rawValue, in: location)
        )
        location.objects.append(object)
        selection = [object.id]
    }

    // MARK: - Hit testing

    /// Minimum touch target, in map points — about 44pt on screen at any zoom.
    private var touchSlop: Double { 22 / Double(max(zoom, 0.01)) }

    /// Topmost-first hit test, so the object drawn last (visually on top) is
    /// the one a tap grabs — the same z-order SVG gives you for free.
    private func hitTest(_ point: CGPoint, where include: (LocationObject) -> Bool = { _ in true }) -> LocationObject? {
        location.objects.reversed().first { include($0) && hits($0, point) }
    }

    private func hits(_ object: LocationObject, _ point: CGPoint) -> Bool {
        guard let tool = LocationTools.tool(forType: object.type) else { return false }
        switch tool {
        case .area:
            return hitTestPolyline(object, point: point)
        case .icon:
            let half: Double = max(Double(LocationIconRenderer.nominalSize.width) * max(object.scale, 0.2) / 2, touchSlop)
            return abs(point.x - object.x) <= half && abs(point.y - object.y) <= half
        case .shape, .select:
            return abs(point.x - object.x) <= max(object.width / 2, touchSlop)
                && abs(point.y - object.y) <= max(object.height / 2, touchSlop)
        }
    }

    /// Areas are hit-tested against their path rather than a bounding box —
    /// a lake's box can cover most of the map while the lake itself doesn't.
    private func hitTestPolyline(_ object: LocationObject, point: CGPoint) -> Bool {
        let points = object.points.compactMap { $0.count >= 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        guard points.count >= 2 else { return false }
        if object.type == LocationTools.Area.road.rawValue {
            // Roads are open strokes: near any segment, within its width.
            let tolerance = max(object.strokeWidth / 2, touchSlop)
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
        let isSelected = selection.contains(object.id)

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

    /// Constant on screen rather than in map points, so a selection stays
    /// visible when zoomed far out.
    private func strokeSelection(_ path: Path, in context: inout GraphicsContext) {
        let z = max(zoom, 0.01)
        context.stroke(path, with: .color(.accentColor),
                       style: StrokeStyle(lineWidth: 2 / z, dash: [5 / z, 3 / z]))
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
        if case .marquee? = drag, let start = dragStart, let current = dragCurrent {
            let rect = Path(CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                                   width: abs(current.x - start.x), height: abs(current.y - start.y)))
            context.fill(rect, with: .color(Color.accentColor.opacity(0.1)))
            context.stroke(rect, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.5 / zoom, dash: [6 / zoom, 4 / zoom]))
        }
        if case .draw? = drag, case .shape(let shape) = tool, let start = dragStart, let current = dragCurrent {
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
