import XCTest
@testable import Nostalgex

/// The rule these lock down: a library load is judged by whether it is still moving, never
/// by how long it has been running. A big library on a thin connection is allowed to take
/// as long as it takes; only silence is treated as a stall.
final class LibraryLoadStallDetectorTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func sample(section: Int = 0, items: Int = 0, detail: String = "") -> LibraryLoadProgressSample {
        LibraryLoadProgressSample(
            phase: LibraryLoadPhase.scanningLibrary.rawValue,
            sectionIndex: section,
            totalSections: 4,
            itemsFound: items,
            detail: detail
        )
    }

    // MARK: - Slow but working

    func testSlowScanNeverStallsWhileItemsKeepArriving() {
        var detector = LibraryLoadStallDetector(start: sample(), at: start)
        // 40 minutes of real work, one page every 90s: far past any total-time budget.
        for step in 1...25 {
            let now = start.addingTimeInterval(Double(step) * 90)
            let verdict = detector.evaluate(sample(items: step * 150), at: now)
            XCTAssertEqual(verdict, .progressing, "step \(step) should still count as progress")
        }
    }

    func testShowLevelDetailCountsAsProgressWhenCountersHaveNotMoved() {
        // A TV section reports "60/130 shows" between page landings. Without the detail
        // line those minutes look identical to a frozen scan.
        var detector = LibraryLoadStallDetector(start: sample(detail: "Section 1/4 · 10/130 shows"), at: start)
        var now = start
        for shows in stride(from: 20, through: 130, by: 10) {
            now = now.addingTimeInterval(120)
            let verdict = detector.evaluate(sample(detail: "Section 1/4 · \(shows)/130 shows"), at: now)
            XCTAssertEqual(verdict, .progressing)
        }
    }

    func testMovingToTheNextSectionIsProgress() {
        var detector = LibraryLoadStallDetector(start: sample(section: 0, items: 900), at: start)
        let verdict = detector.evaluate(sample(section: 1, items: 900), at: start.addingTimeInterval(200))
        XCTAssertEqual(verdict, .progressing)
    }

    // MARK: - Going quiet

    func testQuietPastWarnThresholdIsSlowNotStalled() {
        var detector = LibraryLoadStallDetector(start: sample(items: 500), at: start)
        XCTAssertEqual(
            detector.evaluate(sample(items: 500), at: start.addingTimeInterval(61)),
            .slow(secondsWithoutProgress: 61)
        )
    }

    func testStaysProgressingJustBeforeWarnThreshold() {
        var detector = LibraryLoadStallDetector(start: sample(items: 500), at: start)
        XCTAssertEqual(
            detector.evaluate(sample(items: 500), at: start.addingTimeInterval(59)),
            .progressing
        )
    }

    func testFullRetryLadderIsNotLongEnoughToStall() {
        // Three 60s request timeouts plus backoff is ~181s of legitimate silence that ends
        // in a real error. The watchdog must sit above it.
        var detector = LibraryLoadStallDetector(start: sample(items: 500), at: start)
        let verdict = detector.evaluate(sample(items: 500), at: start.addingTimeInterval(182))
        XCTAssertEqual(verdict, .slow(secondsWithoutProgress: 182))
    }

    func testSilencePastStallThresholdStalls() {
        var detector = LibraryLoadStallDetector(start: sample(items: 500), at: start)
        XCTAssertEqual(
            detector.evaluate(sample(items: 500), at: start.addingTimeInterval(210)),
            .stalled(secondsWithoutProgress: 210)
        )
    }

    func testStallClockResetsOnEveryScrapOfProgress() {
        var detector = LibraryLoadStallDetector(start: sample(items: 500), at: start)
        // Quiet for 200s, one page lands, then quiet again for 200s: neither window on its
        // own is a stall, and the total 400s must not add up to one.
        XCTAssertEqual(
            detector.evaluate(sample(items: 500), at: start.addingTimeInterval(200)),
            .slow(secondsWithoutProgress: 200)
        )
        XCTAssertEqual(
            detector.evaluate(sample(items: 650), at: start.addingTimeInterval(201)),
            .progressing
        )
        XCTAssertEqual(
            detector.evaluate(sample(items: 650), at: start.addingTimeInterval(401)),
            .slow(secondsWithoutProgress: 200)
        )
    }

    func testRecoveryAfterStallVerdictIsReportedAsProgress() {
        // A scan that unsticks itself before the watchdog acts on the verdict must clear
        // the warning rather than stay flagged.
        var detector = LibraryLoadStallDetector(start: sample(items: 500), at: start)
        _ = detector.evaluate(sample(items: 500), at: start.addingTimeInterval(300))
        XCTAssertEqual(
            detector.evaluate(sample(items: 501), at: start.addingTimeInterval(302)),
            .progressing
        )
    }

    // MARK: - Thresholds and clock

    func testCustomThresholdsAreHonoured() {
        var detector = LibraryLoadStallDetector(
            start: sample(),
            at: start,
            warnAfter: 5,
            stallAfter: 10
        )
        XCTAssertEqual(detector.evaluate(sample(), at: start.addingTimeInterval(4)), .progressing)
        XCTAssertEqual(detector.evaluate(sample(), at: start.addingTimeInterval(6)), .slow(secondsWithoutProgress: 6))
        XCTAssertEqual(detector.evaluate(sample(), at: start.addingTimeInterval(11)), .stalled(secondsWithoutProgress: 11))
    }

    func testClockMovingBackwardsNeverStalls() {
        // A backwards system clock (NTP correction) must not be read as elapsed silence.
        var detector = LibraryLoadStallDetector(start: sample(), at: start)
        XCTAssertEqual(detector.evaluate(sample(), at: start.addingTimeInterval(-600)), .progressing)
    }

    func testDefaultThresholdsAreOrdered() {
        XCTAssertLessThan(
            LibraryLoadStallDetector.defaultWarnAfter,
            LibraryLoadStallDetector.defaultStallAfter
        )
        // Above the ~181s worst-case retry ladder in PlexAPIService.dataWithRetry.
        XCTAssertGreaterThan(LibraryLoadStallDetector.defaultStallAfter, 182)
    }
}
