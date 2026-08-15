import Foundation

/// Pure geometry helpers shared by `TimelineView`/`TimelineConfigView`, ported
/// from app.js's timeline gap/zoom helpers (app.js:765-810, 1227-1268). Kept
/// as static functions over an `EventOrder` (rather than methods on the
/// struct) so call sites read like the mutations they are — every function
/// here either computes a y position or mutates event placement in response
/// to a marker/gap/zoom change.
enum TimelineGeometry {
    static let topPad: Double = 16

    /// Mirrors `markerY` (app.js:766-773): the y position of marker `index`,
    /// honoring per-marker `gapSizes` when present and matching the marker
    /// count, else uniform `pixelsPerMarker` spacing.
    static func markerY(_ index: Int, order: EventOrder) -> Double {
        let cfg = order.timelineConfig
        let markers = TimelineMath.generateMarkers(cfg)
        guard let gaps = cfg.gapSizes, gaps.count == markers.count else {
            return topPad + Double(index) * cfg.pixelsPerMarker
        }
        var y: Double = 0
        var i = 0
        while i < index && i < gaps.count {
            y += gaps[i]
            i += 1
        }
        return topPad + y
    }

    /// Mirrors `totalTlHeight` (app.js:359-366).
    static func totalHeight(order: EventOrder) -> Double {
        let cfg = order.timelineConfig
        let markers = TimelineMath.generateMarkers(cfg)
        if let gaps = cfg.gapSizes, gaps.count == markers.count {
            return topPad + gaps.reduce(0, +)
        }
        return topPad + Double(markers.count) * cfg.pixelsPerMarker
    }

    /// Mirrors `ensureGapSizes` (app.js:774-778).
    static func ensureGapSizes(_ order: inout EventOrder) {
        let markers = TimelineMath.generateMarkers(order.timelineConfig)
        if order.timelineConfig.gapSizes?.count != markers.count {
            order.timelineConfig.gapSizes = Array(repeating: order.timelineConfig.pixelsPerMarker, count: markers.count)
        }
    }

    /// Mirrors `recalcAllEventTimes` (app.js:779-786).
    static func recalcAllEventTimes(_ order: inout EventOrder) {
        let markers = TimelineMath.generateMarkers(order.timelineConfig)
        let cfg = order.timelineConfig
        for colIndex in order.characterColumns.indices {
            for evtIndex in order.characterColumns[colIndex].events.indices {
                let y = order.characterColumns[colIndex].events[evtIndex].yPos
                order.characterColumns[colIndex].events[evtIndex].time = TimelineMath.timeFromY(y, markers: markers, cfg: cfg)
            }
        }
    }

    /// Shifts every event at/below `cutY` down by `delta`. Shared by
    /// `TimelineConfigView.insertLabel` and `growGap`.
    static func shiftEvents(in order: inout EventOrder, atOrBelow cutY: Double, by delta: Double) {
        for colIndex in order.characterColumns.indices {
            for evtIndex in order.characterColumns[colIndex].events.indices {
                if order.characterColumns[colIndex].events[evtIndex].yPos >= cutY {
                    order.characterColumns[colIndex].events[evtIndex].yPos += delta
                }
            }
        }
    }

    /// Mirrors `growGap` (app.js:788-799).
    static func growGap(_ index: Int, order: inout EventOrder) {
        ensureGapSizes(&order)
        guard var gaps = order.timelineConfig.gapSizes, index < gaps.count else { return }
        var cutY = topPad
        for i in 0...index { cutY += gaps[i] }
        gaps[index] += 20
        order.timelineConfig.gapSizes = gaps
        shiftEvents(in: &order, atOrBelow: cutY, by: 20)
        recalcAllEventTimes(&order)
    }

    /// Mirrors `shrinkGap` (app.js:800-810).
    static func shrinkGap(_ index: Int, order: inout EventOrder) {
        ensureGapSizes(&order)
        guard var gaps = order.timelineConfig.gapSizes, index < gaps.count, gaps[index] > 30 else { return }
        var cutY = topPad
        for i in 0...index { cutY += gaps[i] }
        let newGap = max(30, gaps[index] - 20)
        let shrunkBy = gaps[index] - newGap
        gaps[index] = newGap
        order.timelineConfig.gapSizes = gaps
        for colIndex in order.characterColumns.indices {
            for evtIndex in order.characterColumns[colIndex].events.indices {
                if order.characterColumns[colIndex].events[evtIndex].yPos >= cutY {
                    order.characterColumns[colIndex].events[evtIndex].yPos = max(0, order.characterColumns[colIndex].events[evtIndex].yPos - shrunkBy)
                }
            }
        }
        recalcAllEventTimes(&order)
    }

    /// Mirrors `onPpmInput`/`zoomTl`'s shared rescale (app.js:1227-1268):
    /// changing pixels-per-marker rescales every event's position/height and
    /// any custom gap sizes by the same ratio, so the timeline keeps its
    /// proportions instead of just clipping/stretching from the top.
    static func setPixelsPerMarker(_ newValue: Double, order: inout EventOrder) {
        let oldPpm = order.timelineConfig.pixelsPerMarker
        let clamped = min(max(newValue, 30), 300)
        guard clamped != oldPpm else { return }
        let ratio = clamped / oldPpm
        for colIndex in order.characterColumns.indices {
            for evtIndex in order.characterColumns[colIndex].events.indices {
                let evt = order.characterColumns[colIndex].events[evtIndex]
                order.characterColumns[colIndex].events[evtIndex].yPos = max(16, (evt.yPos * ratio).rounded())
                order.characterColumns[colIndex].events[evtIndex].height = max(24, (evt.height * ratio).rounded())
            }
        }
        order.timelineConfig.pixelsPerMarker = clamped
        if let gaps = order.timelineConfig.gapSizes {
            order.timelineConfig.gapSizes = gaps.map { min(max(($0 * ratio).rounded(), 30), 600) }
        }
        recalcAllEventTimes(&order)
    }
}
