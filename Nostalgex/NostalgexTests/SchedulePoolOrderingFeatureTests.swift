import XCTest
@testable import Nostalgex

final class SchedulePoolOrderingFeatureTests: XCTestCase {

    private func movie(_ key: String, _ title: String, addedAt: Int = 0) -> PlexMediaItem {
        PlexMediaItem(
            id: key, title: title, artist: nil, episodeTitle: nil, seTag: nil,
            summary: "", year: 2000, originallyAvailableAt: nil, contentRating: nil,
            duration: 90, ratingKey: key, partKey: nil, container: nil,
            videoCodec: nil, audioCodec: nil, videoProfile: nil, bitrate: nil,
            genres: [], rating: 0, userRating: 0, type: .movie, thumb: nil, art: nil,
            viewCount: 0, addedAt: addedAt, studio: nil, tmdbID: nil, imdbID: nil,
            librarySource: .movie, serverID: nil
        )
    }

    private let day = 1_700_000_000

    // MARK: - Premiere promotion

    /// Airtime of the item at `index`, in seconds from midnight.
    private func airtime(_ items: [PlexMediaItem], at index: Int) -> Int {
        items[0..<index].reduce(0) { $0 + $1.duration * 60 }
    }

    /// A fresh rip airs somewhere inside the premiere window, never overnight.
    func testRecentItemAirsInThePremiereWindow_inABigPool() {
        var items = (0..<40).map { movie("old\($0)", "Old \($0)") }
        items.insert(movie("fresh", "Fresh Rip", addedAt: day - 86400), at: 2)
        let out = SchedulePoolOrdering.promoteRecentlyAdded(items, dayStartUnix: day, channelId: 7)
        let index = try! XCTUnwrap(out.firstIndex { $0.ratingKey == "fresh" })
        let start = airtime(out, at: index)
        XCTAssertGreaterThanOrEqual(start, SchedulePoolOrdering.premiereAnchorSeconds)
        // One item of slack: insertion lands on the first slot at or past the target.
        XCTAssertLessThan(
            start,
            SchedulePoolOrdering.premiereAnchorSeconds + SchedulePoolOrdering.premiereSpreadSeconds + 90 * 60
        )
        // Everyone else keeps their relative order.
        XCTAssertEqual(
            out.filter { $0.ratingKey != "fresh" }.map(\.ratingKey),
            (0..<40).map { "old\($0)" }
        )
    }

    /// The bug this window exists to prevent: a film added to several channels used to
    /// premiere at 19:00 on every one of them, so the guide showed Point Break six times
    /// in the same slot. Slots are per (channel, item), so the airtimes must differ.
    func testSameFilmPremieresAtDifferentTimesAcrossChannels() {
        var starts: Set<Int> = []
        for channelId in [3, 14, 27, 42, 63, 79] {
            var items = (0..<40).map { movie("old\($0)", "Old \($0)") }
            items.insert(movie("point-break", "Point Break", addedAt: day - 3600), at: 5)
            let out = SchedulePoolOrdering.promoteRecentlyAdded(items, dayStartUnix: day, channelId: channelId)
            let index = try! XCTUnwrap(out.firstIndex { $0.ratingKey == "point-break" })
            starts.insert(airtime(out, at: index))
        }
        XCTAssertGreaterThan(starts.count, 1, "a new film must not premiere at one time on every channel")
    }

    /// Same channel, same item, same day: the manifest has to be reproducible.
    func testPremiereSlotIsDeterministic() {
        let a = SchedulePoolOrdering.premiereOffset(channelId: 14, ratingKey: "point-break")
        let b = SchedulePoolOrdering.premiereOffset(channelId: 14, ratingKey: "point-break")
        XCTAssertEqual(a, b)
        XCTAssertGreaterThanOrEqual(a, SchedulePoolOrdering.premiereAnchorSeconds)
        XCTAssertLessThan(a, SchedulePoolOrdering.premiereAnchorSeconds + SchedulePoolOrdering.premiereSpreadSeconds)
    }

    /// A pool shorter than the anchor appends recents at the end — still the same evening,
    /// never displaced to an already-elapsed slot.
    func testRecentItemGoesLast_inASmallPool() {
        let items = [
            movie("a", "Old One"),
            movie("b", "Older One"),
            movie("c", "Fresh Rip", addedAt: day - 86400),
            movie("d", "Ancient One"),
        ]
        let out = SchedulePoolOrdering.promoteRecentlyAdded(items, dayStartUnix: day, channelId: 1)
        XCTAssertEqual(out.map(\.ratingKey), ["a", "b", "d", "c"])
    }

    func testOutsideWindow_notPromoted() {
        let stale = day - SchedulePoolOrdering.premiereWindowSeconds - 1
        let items = [movie("a", "Old"), movie("b", "Barely Too Old", addedAt: stale)]
        XCTAssertEqual(
            SchedulePoolOrdering.promoteRecentlyAdded(items, dayStartUnix: day, channelId: 1).map(\.ratingKey),
            ["a", "b"]
        )
    }

    /// Backends that don't report an added date send 0; that must read as "not recent",
    /// never as "added at epoch start but somehow fresh".
    func testZeroAddedAt_neverPromoted() {
        let items = [movie("a", "First"), movie("b", "Second", addedAt: 0)]
        XCTAssertEqual(
            SchedulePoolOrdering.promoteRecentlyAdded(items, dayStartUnix: day, channelId: 1).map(\.ratingKey),
            ["a", "b"]
        )
    }

    /// Everything recent means nothing needs to move — a fresh library isn't reordered.
    func testAllRecent_unchanged() {
        let items = [
            movie("a", "One", addedAt: day - 100),
            movie("b", "Two", addedAt: day - 200),
        ]
        XCTAssertEqual(
            SchedulePoolOrdering.promoteRecentlyAdded(items, dayStartUnix: day, channelId: 1).map(\.ratingKey),
            ["a", "b"]
        )
    }

    // MARK: - Sequel adjacency

    func testPartsPairUp_atEarliestPosition_inPartOrder() {
        let items = [
            movie("x", "Some Film"),
            movie("p2", "Mockingjay Part 2"),
            movie("y", "Another Film"),
            movie("p1", "Mockingjay Part 1"),
        ]
        let out = SchedulePoolOrdering.groupSequelParts(items)
        XCTAssertEqual(out.map(\.ratingKey), ["x", "p1", "p2", "y"])
    }

    func testThreeParts_orderedByOrdinal() {
        let items = [
            movie("c", "Saga pt. 3"),
            movie("a", "Saga pt. 1"),
            movie("b", "Saga pt. 2"),
        ]
        XCTAssertEqual(
            SchedulePoolOrdering.groupSequelParts(items).map(\.ratingKey),
            ["a", "b", "c"]
        )
    }

    func testLonePartTwo_staysPut() {
        let items = [movie("a", "Alpha"), movie("b", "Orphan Part 2"), movie("c", "Beta")]
        XCTAssertEqual(
            SchedulePoolOrdering.groupSequelParts(items).map(\.ratingKey),
            ["a", "b", "c"]
        )
    }

    /// "The Departed" contains "part"; a marker only counts at the end of the title.
    func testPartInsideWord_orMidTitle_ignored() {
        let items = [
            movie("a", "The Departed"),
            movie("b", "Part 1 of My Life Story"),
            movie("c", "The Departed"),
        ]
        XCTAssertEqual(
            SchedulePoolOrdering.groupSequelParts(items).map(\.ratingKey),
            ["a", "b", "c"]
        )
    }

    func testDifferentBases_dontMerge() {
        let items = [
            movie("h2", "Deathly Hallows Part 2"),
            movie("m1", "Mockingjay Part 1"),
            movie("h1", "Deathly Hallows Part 1"),
            movie("m2", "Mockingjay Part 2"),
        ]
        let out = SchedulePoolOrdering.groupSequelParts(items).map(\.ratingKey)
        XCTAssertEqual(out, ["h1", "h2", "m1", "m2"])
    }

    // MARK: - Jellyfin DateCreated parsing

    func testUnixSeconds_parsesISOWithAndWithoutFraction() {
        XCTAssertEqual(JellyfinAPIService.unixSeconds(fromISO: "2026-08-20T12:00:00Z"), 1787227200)
        XCTAssertEqual(JellyfinAPIService.unixSeconds(fromISO: "2026-08-20T12:00:00.0000000Z"), 1787227200)
    }

    func testUnixSeconds_failuresReadAsNotRecent() {
        XCTAssertEqual(JellyfinAPIService.unixSeconds(fromISO: nil), 0)
        XCTAssertEqual(JellyfinAPIService.unixSeconds(fromISO: "not a date"), 0)
    }
}
