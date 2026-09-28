import Foundation
import CoreGraphics

/// Converts a channel's schedule intervals into leading-aligned EPG row segments.
///
/// The guide previously tiled program blocks end-to-end and assumed the schedule was
/// perfectly contiguous. Real schedules are not. A gap between entries (time-restricted
/// channels have whole stretches with no blocks) silently pulled every later block left
/// of its true time, and overlapping entries double-counted width so the row's content
/// grew wider than its container — and an overflowing fixed-width SwiftUI frame centers
/// its content, sliding the entire row left. In the field that looked like: current
/// programs with their titles clipped under the channel column ("orn Family: C…"),
/// upcoming shows drawn tens of minutes early, and rows disagreeing with the now-line.
///
/// Walking a cursor from the window start makes the fractions sum to exactly the span
/// they cover: gaps become explicit spacers, overlap is trimmed from the later entry,
/// and no input can produce content wider than the window.
enum ProgramRowLayout {

    enum Segment: Equatable {
        /// Empty air between programs, at its true position.
        case gap(fraction: CGFloat)
        /// A visible slice of the entry at `index` in the ORIGINAL entries array.
        case block(index: Int, fraction: CGFloat)

        var fraction: CGFloat {
            switch self {
            case .gap(let f): return f
            case .block(_, let f): return f
            }
        }
    }

    /// `intervals` must parallel the caller's entries array; segments refer back by index.
    /// Entries are processed in chronological order regardless of input order, but indices
    /// always point into the array as given.
    static func segments(
        intervals: [(start: Date, end: Date)],
        windowStart: Date,
        windowDuration: TimeInterval
    ) -> [Segment] {
        guard windowDuration > 0 else { return [] }
        let windowEnd = windowStart.addingTimeInterval(windowDuration)

        let ordered = intervals.enumerated().sorted { $0.element.start < $1.element.start }

        var segments: [Segment] = []
        var cursor = windowStart

        for (index, interval) in ordered {
            if cursor >= windowEnd { break }

            // Clip against the cursor, not just the window start: the cursor is how the
            // overlap of a mistimed neighbour gets trimmed instead of double-counted.
            let visStart = max(interval.start, cursor)
            let visEnd = min(interval.end, windowEnd)
            guard visEnd > visStart else { continue }

            if visStart > cursor {
                segments.append(.gap(fraction: CGFloat(visStart.timeIntervalSince(cursor) / windowDuration)))
            }
            segments.append(.block(index: index, fraction: CGFloat(visEnd.timeIntervalSince(visStart) / windowDuration)))
            cursor = visEnd
        }

        return segments
    }
}
