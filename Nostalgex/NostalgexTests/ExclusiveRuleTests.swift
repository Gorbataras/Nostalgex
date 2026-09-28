import Testing
import Foundation
@testable import Nostalgex

/// Exclusive rules lock content to specific channels by blocking it from every
/// other channel. When an editorial title fails to match, the title does not
/// disappear, it leaks onto channels it was meant to be kept off. That failure
/// is silent, which is why it went unnoticed: HOLIDAZE carries 49 editorial
/// titles and SCREAM ADULTS carries 8, and Plex's TMDB agent routinely stores
/// films with a " (YYYY)" suffix that the exact match did not account for.
struct ExclusiveRuleTests {

    private func movie(_ title: String, genres: [String] = []) -> PlexMediaItem {
        PlexMediaItem(
            id: "1",
            title: title,
            artist: nil,
            episodeTitle: nil,
            seTag: nil,
            summary: "",
            year: nil,
            originallyAvailableAt: nil,
            contentRating: nil,
            duration: 90,
            ratingKey: "1",
            partKey: nil,
            container: "mkv",
            videoCodec: nil,
            audioCodec: nil,
            videoProfile: nil,
            bitrate: nil,
            genres: genres,
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
            librarySource: .movie
        )
    }

    private var holidazeRule: ExclusiveRule {
        ExclusiveRule(
            channelIDs: [130],
            genres: ["Holiday", "Christmas"],
            titleContains: ["Christmas", "Santa"],
            editorialTitles: ["Elf", "Home Alone", "It's a Wonderful Life"],
            manifestExclusive: false
        )
    }

    @Test func editorialTitleMatchesExactly() {
        #expect(holidazeRule.matches(movie("Elf")))
        #expect(holidazeRule.matches(movie("home alone")))
    }

    // The regression: Plex stores "Elf (2003)", the config says "Elf".
    @Test func editorialTitleMatchesDespitePlexYearSuffix() {
        #expect(holidazeRule.matches(movie("Elf (2003)")))
        #expect(holidazeRule.matches(movie("Home Alone (1990)")))
        #expect(holidazeRule.matches(movie("It's a Wonderful Life (1946)")))
    }

    @Test func unrelatedTitleIsNotClaimed() {
        #expect(!holidazeRule.matches(movie("Die Hard (1988)")))
        #expect(!holidazeRule.matches(movie("Elf Quest (1999)")))
    }

    // A year in the middle of a title is part of the title, not a Plex suffix.
    @Test func onlyATrailingYearSuffixIsIgnored() {
        let rule = ExclusiveRule(
            channelIDs: [130],
            genres: [],
            titleContains: [],
            editorialTitles: ["Blade Runner 2049"],
            manifestExclusive: false
        )
        #expect(rule.matches(movie("Blade Runner 2049")))
        #expect(rule.matches(movie("Blade Runner 2049 (2017)")))
    }

    @Test func titleContainsAndGenreStillMatch() {
        #expect(holidazeRule.matches(movie("The Christmas Chronicles (2018)")))
        #expect(holidazeRule.matches(movie("Some Winter Film", genres: ["Holiday"])))
        #expect(!holidazeRule.matches(movie("Some Winter Film", genres: ["Drama"])))
    }
}
