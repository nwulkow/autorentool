import SwiftUI

/// Draws the ten map icons, ported from the inline SVG `<g>` blocks in app.js
/// (app.js:2458-2537). Each icon is authored in the same local coordinate
/// space the SVG used — origin at the icon's anchor point, roughly ±25pt —
/// then translated and scaled at draw time, exactly like the SVG's
/// `transform="translate(x,y) scale(s)"`.
///
/// Kept as free functions over a `GraphicsContext` rather than SwiftUI shapes
/// so the whole map renders in one `Canvas` pass — hundreds of objects on a
/// map shouldn't mean hundreds of views.
enum LocationIconRenderer {

    /// Draws `icon` centered on the origin of the already-transformed context.
    static func draw(_ icon: LocationTools.Icon, in context: inout GraphicsContext, color: Color, stroke: Color) {
        switch icon {
        case .tree:    drawTree(&context, color)
        case .house:   drawHouse(&context, color, stroke)
        case .castle:  drawCastle(&context, color)
        case .car:     drawCar(&context, color)
        case .bed:     drawBed(&context, color)
        case .table:   drawTable(&context, color)
        case .door:    drawDoor(&context, color)
        case .shop:    drawShop(&context, color)
        case .building: drawBuilding(&context, color)
        case .fountain: drawFountain(&context, color)
        }
    }

    /// The icon's untransformed bounding box, used to hit-test taps and to
    /// place the name label below it. app.js stores `width`/`height` of 40 on
    /// icon objects and uses that for the label offset (app.js:2549-2551).
    static let nominalSize: CGSize = CGSize(width: 40, height: 40)

    // MARK: - Individual icons

    private static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, radius: Double = 0) -> Path {
        let r = CGRect(x: x, y: y, width: w, height: h)
        return radius > 0 ? Path(roundedRect: r, cornerRadius: radius) : Path(r)
    }

    private static func polygon(_ points: [(Double, Double)]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.0, y: first.1))
        for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
        path.closeSubpath()
        return path
    }

    private static let brown = Color(red: 0.545, green: 0.271, blue: 0.075)   // #8B4513
    private static let amber = Color(red: 0.945, green: 0.769, blue: 0.059)   // #f1c40f
    private static let orange = Color(red: 0.953, green: 0.612, blue: 0.071)  // #f39c12
    private static let darkSlate = Color(red: 0.173, green: 0.243, blue: 0.314) // #2c3e50
    private static let gray55 = Color(white: 0.333)                            // #555
    private static let concrete = Color(red: 0.584, green: 0.647, blue: 0.651) // #95a5a6
    private static let brick = Color(red: 0.753, green: 0.224, blue: 0.169)    // #c0392b
    private static let waterBlue = Color(red: 0.204, green: 0.596, blue: 0.859).opacity(0.5)

    /// app.js:2477-2481
    private static func drawTree(_ ctx: inout GraphicsContext, _ color: Color) {
        ctx.fill(polygon([(0, -25), (18, 10), (-18, 10)]), with: .color(color))
        ctx.fill(rect(-4, 10, 8, 10), with: .color(brown))
    }

    /// app.js:2483-2488
    private static func drawHouse(_ ctx: inout GraphicsContext, _ color: Color, _ stroke: Color) {
        ctx.fill(rect(-18, -5, 36, 28), with: .color(color))
        ctx.fill(polygon([(-22, -5), (0, -25), (22, -5)]), with: .color(stroke))
        ctx.fill(rect(-5, 5, 10, 18), with: .color(orange))
    }

    /// app.js:2490-2497
    private static func drawCastle(_ ctx: inout GraphicsContext, _ color: Color) {
        ctx.fill(rect(-24, -8, 48, 32), with: .color(color))
        ctx.fill(rect(-24, -18, 10, 10), with: .color(color))
        ctx.fill(rect(-5, -18, 10, 10), with: .color(color))
        ctx.fill(rect(14, -18, 10, 10), with: .color(color))
        ctx.fill(rect(-4, 6, 8, 18), with: .color(gray55))
    }

    /// app.js:2499-2504
    private static func drawCar(_ ctx: inout GraphicsContext, _ color: Color) {
        ctx.fill(rect(-22, -6, 44, 16, radius: 3), with: .color(color))
        ctx.fill(rect(-14, -14, 28, 10, radius: 3), with: .color(color.opacity(0.75)))
        ctx.fill(Path(ellipseIn: CGRect(x: -18, y: 7, width: 10, height: 10)), with: .color(darkSlate))
        ctx.fill(Path(ellipseIn: CGRect(x: 8, y: 7, width: 10, height: 10)), with: .color(darkSlate))
    }

    /// app.js:2506-2512
    private static func drawBed(_ ctx: inout GraphicsContext, _ color: Color) {
        ctx.fill(rect(-18, -4, 36, 16, radius: 2), with: .color(color))
        ctx.fill(rect(-18, -10, 6, 22, radius: 1), with: .color(color.opacity(0.8)))
        ctx.fill(rect(12, 2, 6, 10, radius: 1), with: .color(color.opacity(0.6)))
        ctx.fill(rect(-14, -2, 12, 8, radius: 3), with: .color(.white.opacity(0.35)))
    }

    /// app.js:2514-2519
    private static func drawTable(_ ctx: inout GraphicsContext, _ color: Color) {
        ctx.fill(rect(-18, -4, 36, 5, radius: 1), with: .color(color))
        ctx.fill(rect(-14, 1, 3, 14), with: .color(color.opacity(0.7)))
        ctx.fill(rect(11, 1, 3, 14), with: .color(color.opacity(0.7)))
    }

    /// app.js:2521-2525
    private static func drawDoor(_ ctx: inout GraphicsContext, _ color: Color) {
        ctx.fill(rect(-8, -16, 16, 32, radius: 1), with: .color(color))
        ctx.fill(Path(ellipseIn: CGRect(x: 2, y: 0, width: 4, height: 4)), with: .color(amber))
    }

    /// app.js:2527-2532
    private static func drawShop(_ ctx: inout GraphicsContext, _ color: Color) {
        ctx.fill(rect(-18, -4, 36, 24), with: .color(color))
        ctx.fill(polygon([(-20, -4), (-20, -12), (20, -12), (20, -4)]), with: .color(brick.opacity(0.5)))
        ctx.fill(rect(-3, 4, 6, 16), with: .color(brown.opacity(0.6)))
    }

    /// app.js:2534-2542
    private static func drawBuilding(_ ctx: inout GraphicsContext, _ color: Color) {
        ctx.fill(rect(-12, -22, 24, 44), with: .color(color))
        for (x, y) in [(-8.0, -16.0), (3.0, -16.0), (-8.0, -6.0), (3.0, -6.0)] {
            ctx.fill(rect(x, y, 5, 5), with: .color(amber.opacity(0.6)))
        }
        ctx.fill(rect(-3, 10, 6, 12), with: .color(gray55))
    }

    /// app.js:2544-2549
    private static func drawFountain(_ ctx: inout GraphicsContext, _ color: Color) {
        ctx.fill(Path(ellipseIn: CGRect(x: -16, y: -2, width: 32, height: 16)), with: .color(color.opacity(0.5)))
        ctx.fill(rect(-2, -10, 4, 16), with: .color(concrete))
        ctx.fill(Path(ellipseIn: CGRect(x: -4, y: -16, width: 8, height: 8)), with: .color(waterBlue))
    }
}
