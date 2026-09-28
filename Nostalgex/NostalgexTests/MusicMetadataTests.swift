import Testing
import Foundation
@testable import Nostalgex

struct MusicMetadataTests {

    @Test func parseArtistDashTitle() {
        let parsed = MusicTitleParser.parse("Michael Jackson - Billie Jean")
        #expect(parsed.artist == "Michael Jackson")
        #expect(parsed.song == "Billie Jean")
    }

    @Test func parseTitleByArtist() {
        let parsed = MusicTitleParser.parse("Billie Jean by Michael Jackson")
        #expect(parsed.artist == "Michael Jackson")
        #expect(parsed.song == "Billie Jean")
    }

    @Test func mapMusicBrainzTagsToChannelGenres() {
        let genres = MusicBrainzService.mapTagsToChannelGenres(["pop rock", "hip hop", "soul"])
        #expect(genres.contains("Pop"))
        #expect(genres.contains("Hip-Hop"))
        #expect(genres.contains("Soul"))
    }

    @Test @MainActor func thinPlexGenresDetected() {
        #expect(MusicEnrichmentService.plexGenresAreThin(["Music Video"]))
        #expect(!MusicEnrichmentService.plexGenresAreThin(["Pop", "Music Video"]))
    }

    @Test func applyingMusicEnrichmentUpdatesDisplayFields() {
        let raw = PlexMediaItem(
            id: "1",
            title: "Thriller.mp4",
            artist: nil,
            episodeTitle: nil,
            seTag: nil,
            summary: "",
            year: nil,
            originallyAvailableAt: nil,
            contentRating: nil,
            duration: 5,
            ratingKey: "1",
            partKey: nil,
            container: "mp4",
            videoCodec: nil,
            audioCodec: nil,
            videoProfile: nil,
            bitrate: nil,
            genres: ["Music Video"],
            rating: 0,
            userRating: 0,
            type: .movie,
            thumb: nil,
            art: nil,
            viewCount: 0,
            addedAt: 0,
            studio: nil,
            tmdbID: nil,
            imdbID: nil,
            librarySource: .musicVideo
        )
        let music = MusicVideoEnrichment(
            ratingKey: "1",
            recordingTitle: "Thriller",
            artist: "Michael Jackson",
            musicBrainzID: "mbid",
            genres: ["Pop", "Rock"],
            releaseYear: 1982,
            fetchedAt: Date()
        )
        let merged = raw.applyingMusicEnrichment(music)
        #expect(merged.title == "Thriller")
        #expect(merged.artist == "Michael Jackson")
        #expect(merged.year == 1982)
        #expect(merged.musicDisplayLine == "Michael Jackson · Thriller")
        #expect(merged.musicGenreDisplay?.contains("Pop") == true)
    }
}
