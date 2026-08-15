import SwiftUI

/// Parses and re-emits the CSS color strings stored in `books/*.json`.
///
/// `LocationObject.color`/`.stroke` are whatever string app.js wrote — either
/// `#rrggbb` (shapes, icons) or `rgba(r,g,b,a)` (the translucent area fills in
/// `AREA_DEFAULTS`, app.js:11-16). Both forms have to survive a round trip
/// through the iOS app, because the same file is opened by the Mac app after
/// Dropbox sync: parsing `rgba(...)` and writing back `#rrggbb` would silently
/// drop the alpha and turn a see-through lake opaque there.
///
/// So this keeps alpha in the model and re-serializes in whichever form the
/// value needs: `#rrggbb` when fully opaque, `rgba(...)` otherwise — matching
/// what app.js itself produces.
enum CSSColor {
    /// Parsed CSS color as straight components, alpha included.
    struct Components: Equatable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double
    }

    /// Accepts `#rgb`, `#rrggbb`, `rgb(r,g,b)` and `rgba(r,g,b,a)`.
    /// Returns `nil` for anything unrecognized so callers can fall back
    /// rather than render a wrong color.
    static func parse(_ string: String) -> Components? {
        let trimmed = string.trimmingCharacters(in: .whitespaces).lowercased()

        if trimmed.hasPrefix("#") {
            let hex = String(trimmed.dropFirst())
            let expanded: String
            switch hex.count {
            case 3: expanded = hex.map { "\($0)\($0)" }.joined()
            case 6: expanded = hex
            default: return nil
            }
            guard let value = UInt32(expanded, radix: 16) else { return nil }
            return Components(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255,
                alpha: 1
            )
        }

        guard trimmed.hasPrefix("rgb"), let open = trimmed.firstIndex(of: "("), let close = trimmed.lastIndex(of: ")") else {
            return nil
        }
        let parts = trimmed[trimmed.index(after: open)..<close]
            .split(separator: ",")
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3 || parts.count == 4,
              let r = parts[0], let g = parts[1], let b = parts[2] else { return nil }
        let a = parts.count == 4 ? (parts[3] ?? 1) : 1
        return Components(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    /// Inverse of `parse`: `#rrggbb` when opaque, `rgba(...)` when not, so a
    /// translucent area fill stays translucent for the Mac app.
    static func string(from components: Components) -> String {
        let r = Int((components.red * 255).rounded())
        let g = Int((components.green * 255).rounded())
        let b = Int((components.blue * 255).rounded())
        if components.alpha >= 0.999 {
            return String(format: "#%02x%02x%02x", r, g, b)
        }
        // Trailing zeros trimmed so 0.45 stays "0.45", matching AREA_DEFAULTS.
        let alpha = String(format: "%.2f", components.alpha)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
        return "rgba(\(r),\(g),\(b),\(alpha))"
    }

    /// Convenience for rendering; `fallback` is used when the string can't be parsed.
    static func color(_ string: String, fallback: Color = .gray) -> Color {
        guard let c = parse(string) else { return fallback }
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }
}

extension Color {
    /// Round-trips a SwiftUI `Color` back to a CSS string, preserving the
    /// alpha the original string carried (SwiftUI's `ColorPicker` with
    /// `supportsOpacity: false` returns an opaque color, which would
    /// otherwise flatten an area fill's transparency on every edit).
    func cssString(preservingAlphaOf original: String) -> String {
        let originalAlpha = CSSColor.parse(original)?.alpha ?? 1
        let resolved = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return CSSColor.string(from: .init(red: r, green: g, blue: b, alpha: originalAlpha))
    }
}
