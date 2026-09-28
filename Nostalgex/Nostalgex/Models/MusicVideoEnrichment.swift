import Foundation

/// Metadata resolved outside Plex (MusicBrainz + local title parsing) for music-video items.
struct MusicVideoEnrichment: Codable, Sendable, Hashable {
    let ratingKey: String
    /// Song/recording title used for lookup (may differ from Plex `title` when parsed).
    let recordingTitle: String
    /// Primary artist when known (Plex field, parsed from title, or MusicBrainz).
    let artist: String?
    /// MusicBrainz recording MBID when a match was found.
    let musicBrainzID: String?
    /// Genres/tags for channel matching (mapped from MusicBrainz tags + artist tags).
    let genres: [String]
    /// Release year from MusicBrainz when Plex has none.
    let releaseYear: Int?
    let fetchedAt: Date

    var hasUsefulGenres: Bool {
        genres.contains { g in
            let l = g.lowercased()
            return !l.contains("music video") && l != "music" && l != "musical"
        }
    }
}

/// Heuristic parsing for common music-video filename / Plex title patterns.
enum MusicTitleParser {
    /// Strips trailing ` (YYYY)` Plex often appends.
    static func stripYearSuffix(_ title: String) -> String {
        title.replacingOccurrences(of: #" \(\d{4}\)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns `(artist, songTitle)` when the string looks like `Artist - Song` or `Song by Artist`.
    static func parse(_ raw: String) -> (artist: String?, song: String) {
        let cleaned = stripYearSuffix(raw)
        if let sep = cleaned.range(of: " - ") {
            let artist = String(cleaned[..<sep.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let song = String(cleaned[sep.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !artist.isEmpty, !song.isEmpty { return (artist, song) }
        }
        if let sep = cleaned.range(of: " by ", options: [.caseInsensitive, .backwards]) {
            let song = String(cleaned[..<sep.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = String(cleaned[sep.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !artist.isEmpty, !song.isEmpty { return (artist, song) }
        }
        return (nil, cleaned)
    }
}
