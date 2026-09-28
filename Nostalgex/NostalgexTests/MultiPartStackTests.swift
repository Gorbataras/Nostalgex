import XCTest
@testable import Nostalgex

final class MultiPartStackTests: XCTestCase {

    private func src(_ id: String, _ name: String, ticks: Int64? = 36_000_000_000)
        -> (id: String?, name: String?, runTimeTicks: Int64?) { (id, name, ticks) }

    // MARK: - Stacks that must be detected

    func testPartOneAndTwo_detectedInOrder() {
        let stack = MultiPartStack.detect(sources: [
            src("a", "Titanic (1997) part 1.mkv"),
            src("b", "Titanic (1997) part 2.mkv"),
        ])
        XCTAssertEqual(stack?.parts.map(\.id), ["a", "b"])
        XCTAssertEqual(stack?.totalRunTimeTicks, 72_000_000_000)
    }

    func testPtDotVariant_detected() {
        let stack = MultiPartStack.detect(sources: [
            src("a", "Apocalypse Now Redux pt. 1.mp4"),
            src("b", "Apocalypse Now Redux pt. 2.mp4"),
        ])
        XCTAssertEqual(stack?.parts.count, 2)
    }

    func testDiscAndCdVariants_detected() {
        XCTAssertNotNil(MultiPartStack.detect(sources: [
            src("a", "LOTR Extended disc 1.mkv"), src("b", "LOTR Extended disc 2.mkv"),
        ]))
        XCTAssertNotNil(MultiPartStack.detect(sources: [
            src("a", "Movie cd1.avi"), src("b", "Movie cd2.avi"),
        ]))
    }

    /// Server source order is not disc order; the ordinal decides.
    func testOutOfOrderSources_sortedByOrdinal() {
        let stack = MultiPartStack.detect(sources: [
            src("b", "Titanic part 2.mkv"),
            src("a", "Titanic part 1.mkv"),
        ])
        XCTAssertEqual(stack?.parts.map(\.ordinal), [1, 2])
        XCTAssertEqual(stack?.parts.first?.id, "a")
    }

    /// A film whose TITLE contains "Part 2" still stacks by the LAST marker in the name.
    func testTitleContainingPartWord_usesLastMarker() {
        let stack = MultiPartStack.detect(sources: [
            src("a", "The Hunger Games Mockingjay Part 1 - part 1.mkv"),
            src("b", "The Hunger Games Mockingjay Part 1 - part 2.mkv"),
        ])
        XCTAssertEqual(stack?.parts.map(\.id), ["a", "b"])
    }

    // MARK: - Versions that must NOT be treated as parts

    /// The trap: a 1080p and a 4K of the same film are versions. Playing them as parts
    /// would run the movie twice.
    func testAlternateVersions_returnNil() {
        XCTAssertNil(MultiPartStack.detect(sources: [
            src("a", "Titanic (1997) 1080p.mkv"),
            src("b", "Titanic (1997) 2160p.mkv"),
        ]))
    }

    func testOneMarkedOneNot_returnsNil() {
        XCTAssertNil(MultiPartStack.detect(sources: [
            src("a", "Titanic part 1.mkv"),
            src("b", "Titanic.mkv"),
        ]))
    }

    func testDuplicateOrdinals_returnNil() {
        XCTAssertNil(MultiPartStack.detect(sources: [
            src("a", "Titanic part 1.mkv"),
            src("b", "Titanic part 1 (director cut).mkv"),
        ]))
    }

    func testSingleSource_returnsNil() {
        XCTAssertNil(MultiPartStack.detect(sources: [src("a", "Titanic part 1.mkv")]))
    }

    /// "Department 2" must not read as a part marker mid-word.
    func testMarkerInsideWord_doesNotMatch() {
        XCTAssertNil(MultiPartStack.detect(sources: [
            src("a", "Department 2.mkv"),
            src("b", "Department 2 sequel.mkv"),
        ]))
    }

    /// Missing runtime on any part keeps the total nil rather than lying short.
    func testMissingTicksOnOnePart_totalIsNil() {
        let stack = MultiPartStack.detect(sources: [
            src("a", "Titanic part 1.mkv"),
            src("b", "Titanic part 2.mkv", ticks: nil),
        ])
        XCTAssertNotNil(stack)
        XCTAssertNil(stack?.totalRunTimeTicks)
    }

    // MARK: - Device codec gate

    func testHEVCExcludedWhenDeviceCannotDecode() {
        XCTAssertFalse(CodecSupport.directPlayVideoCodecs(hevcCapable: false).contains("hevc"))
        XCTAssertTrue(CodecSupport.directPlayVideoCodecs(hevcCapable: true).contains("hevc"))
        XCTAssertTrue(CodecSupport.directPlayVideoCodecs(hevcCapable: false).contains("h264"))
    }
}
