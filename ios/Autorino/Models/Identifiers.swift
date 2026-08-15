import Foundation

/// Mirrors app.js's `uid()` helper — short random id, used whenever a
/// legacy JSON file is missing an id field (matches `c.id || uid()` etc.
/// throughout `deserializeBook`).
enum IDGenerator {
    static func uid() -> String {
        UUID().uuidString.lowercased()
    }
}
