import XCTest
@testable import Nostalgex

final class ProgramRowLayoutTests: XCTestCase {

    private let windowStart = Date(timeIntervalSince1970: 1_700_000_000)
    private let twoHours: TimeInterval = 7200

    private func at(_ minutes: Double) -> Date {
        windowStart.addingTimeInterval(minutes * 60)
    }

    private func totalFraction(_ segments: [ProgramRowLayout.Segment]) -> CGFloat {
        segments.reduce(0) { $0 + $1.fraction }
    }

    // MARK: - The invariant everything else depends on

    /// No input may produce content wider than the window. Overflow is what let SwiftUI
    /// center the row's content and slide every block left of its true time.
    func testFractionsNeverSumPastOne() {
        let pathological: [(start: Date, end: Date)] = [
            (at(-500), at(90)),    // huge entry from the past
            (at(0), at(90)),       // full overlap with the first
            (at(30), at(200)),     // overlaps and runs past the window
            (at(45), at(46)),      // nested sliver
            (at(100), at(400)),    // tail entry running far past the end
        ]
        let segments = ProgramRowLayout.segments(
            intervals: pathological, windowStart: windowStart, windowDuration: twoHours
        )
        XCTAssertLessThanOrEqual(totalFraction(segments), 1.0 + 0.0001)
        for segment in segments {
            XCTAssertGreaterThan(segment.fraction, 0)
        }
    }

    // MARK: - Field failure 1: mid-window entry straddling the window start

    /// The current program usually began before the visible window. Its block must be
    /// clipped to start AT the window edge — the old tiling let its full width push the
    /// row into overflow, which is why titles rendered as "orn Family: C…".
    func testEntryStraddlingWindowStartIsClippedToWindow() {
        let intervals: [(start: Date, end: Date)] = [
            (at(-30), at(30)),   // began half an hour before the window
            (at(30), at(120)),
        ]
        let segments = ProgramRowLayout.segments(
            intervals: intervals, windowStart: windowStart, windowDuration: twoHours
        )
        XCTAssertEqual(segments, [
            .block(index: 0, fraction: 0.25),   // only the visible 30 min
            .block(index: 1, fraction: 0.75),
        ])
    }

    // MARK: - Field failure 2: gaps must hold their position

    /// A time-restricted channel has dead air. The old tiling collapsed it, pulling
    /// every later program left of its true slot ("The Hobbit" drawn ~44 minutes early).
    func testGapBetweenEntriesBecomesAnExplicitSpacer() {
        let intervals: [(start: Date, end: Date)] = [
            (at(0), at(30)),
            (at(60), at(120)),   // 30-minute hole before this one
        ]
        let segments = ProgramRowLayout.segments(
            intervals: intervals, windowStart: windowStart, windowDuration: twoHours
        )
        XCTAssertEqual(segments, [
            .block(index: 0, fraction: 0.25),
            .gap(fraction: 0.25),
            .block(index: 1, fraction: 0.5),
        ])
    }

    /// A channel whose first entry starts mid-window gets leading dead air, not a block
    /// shifted to the left edge.
    func testLeadingGapBeforeFirstEntry() {
        let intervals: [(start: Date, end: Date)] = [(at(60), at(120))]
        let segments = ProgramRowLayout.segments(
            intervals: intervals, windowStart: windowStart, windowDuration: twoHours
        )
        XCTAssertEqual(segments, [
            .gap(fraction: 0.5),
            .block(index: 0, fraction: 0.5),
        ])
    }

    // MARK: - Overlap trimming

    /// When a rebuilt now-playing entry overlaps its neighbour, the later entry loses the
    /// contested minutes instead of the row double-counting them.
    func testOverlappingEntryIsTrimmedNotDoubleCounted() {
        let intervals: [(start: Date, end: Date)] = [
            (at(0), at(60)),
            (at(45), at(105)),   // starts 15 min before its predecessor ends
        ]
        let segments = ProgramRowLayout.segments(
            intervals: intervals, windowStart: windowStart, windowDuration: twoHours
        )
        XCTAssertEqual(segments, [
            .block(index: 0, fraction: 0.5),
            .block(index: 1, fraction: 0.375),   // 45 visible minutes, not 60
        ])
        XCTAssertEqual(totalFraction(segments), 0.875, accuracy: 0.0001)
    }

    /// An entry entirely swallowed by its predecessor contributes nothing.
    func testNestedEntryIsSkipped() {
        let intervals: [(start: Date, end: Date)] = [
            (at(0), at(60)),
            (at(10), at(40)),
        ]
        let segments = ProgramRowLayout.segments(
            intervals: intervals, windowStart: windowStart, windowDuration: twoHours
        )
        XCTAssertEqual(segments, [.block(index: 0, fraction: 0.5)])
    }

    // MARK: - Ordinary cases stay exact

    func testContiguousDayFillsWindowExactly() {
        let intervals: [(start: Date, end: Date)] = [
            (at(-15), at(45)),
            (at(45), at(90)),
            (at(90), at(150)),   // runs past the end, clipped
        ]
        let segments = ProgramRowLayout.segments(
            intervals: intervals, windowStart: windowStart, windowDuration: twoHours
        )
        XCTAssertEqual(totalFraction(segments), 1.0, accuracy: 0.0001)
        XCTAssertEqual(segments.count, 3)
    }

    func testEntriesEntirelyOutsideWindowProduceNothing() {
        let intervals: [(start: Date, end: Date)] = [
            (at(-120), at(-30)),
            (at(130), at(200)),
        ]
        let segments = ProgramRowLayout.segments(
            intervals: intervals, windowStart: windowStart, windowDuration: twoHours
        )
        XCTAssertTrue(segments.isEmpty)
    }

    func testEmptyScheduleProducesNoSegments() {
        XCTAssertTrue(ProgramRowLayout.segments(
            intervals: [], windowStart: windowStart, windowDuration: twoHours
        ).isEmpty)
    }

    /// Indices refer to the caller's array even when input arrives out of order, so the
    /// view attaches the right title and colors to each block.
    func testIndicesSurviveUnsortedInput() {
        let intervals: [(start: Date, end: Date)] = [
            (at(60), at(120)),   // later entry listed first
            (at(0), at(60)),
        ]
        let segments = ProgramRowLayout.segments(
            intervals: intervals, windowStart: windowStart, windowDuration: twoHours
        )
        XCTAssertEqual(segments, [
            .block(index: 1, fraction: 0.5),
            .block(index: 0, fraction: 0.5),
        ])
    }
}
