import XCTest
@testable import Nostalgex

/// A living room Apple TV had 23,084 items for an 11,542-item server: the same server was
/// in the list twice (URL-keyed legacy entry plus the real one), every pool held every
/// title twice, films aired back to back, and a ratingKey-keyed dictionary trapped.
@MainActor
final class DuplicateServerTests: XCTestCase {
    private let url = "https://192-168-4-79.c3e917fc09454808a70f0239b82d0c6a.plex.direct:32400"
    private var legacy: AppState.ServerRef { .init(machineIdentifier: url, name: "Plex Server", baseURL: url, owned: true, token: "t") }
    private var real: AppState.ServerRef { .init(machineIdentifier: "4d19f9f3e85290a83d98f832d88f8f88360b7573", name: "Media Mini", baseURL: url, owned: true, token: "t") }
    private var other: AppState.ServerRef { .init(machineIdentifier: "ffff", name: "Loft", baseURL: "https://10-0-0-9.abc.plex.direct:32400", owned: true, token: "t") }

    func testLegacyAndRealEntriesForOneServerCollapseToTheRealOne() {
        let out = AppState.dedupingServers([legacy, real, other])
        XCTAssertEqual(out.map(\.machineIdentifier), [real.machineIdentifier, "ffff"])
        XCTAssertEqual(out.first?.name, "Media Mini", "the real entry's name replaces the migration placeholder")
    }

    func testOrderIndependent() {
        XCTAssertEqual(AppState.dedupingServers([real, legacy]).count, 1)
        XCTAssertEqual(AppState.dedupingServers([legacy]).count, 1, "a lone legacy entry is still a valid server")
    }

    private func item(_ rk: String, server: String) -> PlexMediaItem {
        PlexMediaItem(id: "\(server):\(rk)", title: "T\(rk)", artist: nil, episodeTitle: nil, seTag: nil, summary: "", year: nil,
                      originallyAvailableAt: nil, contentRating: nil, duration: 90, ratingKey: rk, partKey: "/library/parts/\(rk)/x.mkv",
                      container: "mkv", videoCodec: "h264", audioCodec: "aac", videoProfile: nil, bitrate: nil, genres: [], rating: 0,
                      userRating: 0, type: .movie, thumb: nil, art: nil, viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil,
                      librarySource: .movie, serverID: server, additionalPartKeys: nil)
    }

    func testItemsFromTheSameServerUnderTwoIdentitiesAreDeduped() {
        let items = [item("47383", server: url), item("47383", server: real.machineIdentifier), item("18", server: url), item("18", server: real.machineIdentifier)]
        let out = AppState.dedupingItems(items, servers: [real])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(Set(out.map(\.ratingKey)), ["47383", "18"])
    }

    func testItemsFromDifferentServersSharingARatingKeyBothSurvive() {
        let items = [item("1", server: real.machineIdentifier), item("1", server: "ffff")]
        XCTAssertEqual(AppState.dedupingItems(items, servers: [real, other]).count, 2)
    }

    func testEnrichmentRefreshNoLongerTrapsOnDuplicateRatingKeys() {
        let dup = [item("47383", server: url), item("47383", server: real.machineIdentifier)]
        let channel = Channel(id: 1, number: 1, name: "X", color: .blue, category: nil, rules: nil, timeRestrictions: nil, minItems: 0, itemPool: dup)
        _ = MusicEnrichmentService().refreshChannelPools([channel], from: dup)  // used to be a fatal error
    }
}
