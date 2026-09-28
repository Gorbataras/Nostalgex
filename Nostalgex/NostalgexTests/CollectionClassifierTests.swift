import XCTest
@testable import Nostalgex

final class CollectionClassifierTests: XCTestCase {

    private func item(_ title: String) -> PlexMediaItem {
        PlexMediaItem(
            id: title, title: title, artist: nil, episodeTitle: nil, seTag: nil,
            summary: "", year: 2000, originallyAvailableAt: nil, contentRating: nil,
            duration: 90, ratingKey: title, partKey: nil, container: nil,
            videoCodec: nil, audioCodec: nil, videoProfile: nil, bitrate: nil,
            genres: [], rating: 0, userRating: 0, type: .movie, thumb: nil, art: nil,
            viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil, librarySource: .movie
        )
    }

    // Generated list/overlay collections must land in Custom, never Franchises/Actors.
    func testGeneratedListCollectionsAreCustom() {
        let names = [
            "Anilist Popular", "IMDb Popular", "TMDb Popular", "Plex Popular",
            "MyAnimeList Favorited", "MyAnimeList Top Rated", "Anilist Top Rated",
            "Trakt Trending", "Letterboxd Top 250", "Recently Added"
        ]
        for name in names {
            XCTAssertEqual(CollectionClassifier.classify(title: name, items: []), .custom,
                           "\(name) should be Custom")
        }
    }

    // Real actor/director collections still classify as Notable Stars.
    func testPersonNamesAreActors() {
        XCTAssertEqual(CollectionClassifier.classify(title: "Tom Hanks", items: []), .actors)
        XCTAssertEqual(CollectionClassifier.classify(title: "Christopher Nolan", items: []), .actors)
    }

    // Known + repeating-name franchises still classify as Franchises (guard didn't over-catch).
    func testFranchisesStillDetected() {
        XCTAssertEqual(CollectionClassifier.classify(title: "James Bond Collection", items: []), .franchises)
        let topGun = [item("Top Gun"), item("Top Gun: Maverick"), item("Top Gun II")]
        XCTAssertEqual(CollectionClassifier.classify(title: "Top Gun Collection", items: topGun), .franchises)
    }
}
