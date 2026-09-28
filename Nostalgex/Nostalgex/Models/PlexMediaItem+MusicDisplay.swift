import Foundation

extension PlexMediaItem {

    var isMusicVideo: Bool {
        type != .episode && (librarySource ?? .movie) == .musicVideo
    }

    /// Merges MusicBrainz (and parsed) metadata into the item used for UI and schedules.
    func applyingMusicEnrichment(_ music: MusicVideoEnrichment) -> PlexMediaItem {
        guard isMusicVideo else { return self }

        let resolvedTitle = music.recordingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = resolvedTitle.isEmpty ? title : resolvedTitle
        let newArtist = music.artist ?? artist

        var mergedGenres = genres
        for g in music.genres {
            if !mergedGenres.contains(where: { $0.caseInsensitiveCompare(g) == .orderedSame }) {
                mergedGenres.append(g)
            }
        }

        let newYear = year ?? music.releaseYear

        return PlexMediaItem(
            id: id,
            title: newTitle,
            artist: newArtist,
            episodeTitle: episodeTitle,
            seTag: seTag,
            summary: summary,
            year: newYear,
            originallyAvailableAt: originallyAvailableAt,
            contentRating: contentRating,
            duration: duration,
            ratingKey: ratingKey,
            partKey: partKey,
            container: container,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            videoProfile: videoProfile,
            bitrate: bitrate,
            genres: mergedGenres,
            rating: rating,
            userRating: userRating,
            type: type,
            thumb: thumb,
            art: art,
            viewCount: viewCount,
            addedAt: addedAt,
            studio: studio,
            tmdbID: tmdbID,
            imdbID: imdbID,
            librarySource: librarySource
        )
    }

    /// Single-line label for guide grids and compact rows.
    var musicDisplayLine: String {
        guard isMusicVideo else { return title }
        // Middle dot, not an em dash: matches the web tuner's now-playing label
        // (plex-tuner.html) so the same track reads identically on both surfaces.
        if let artist, !artist.isEmpty { return "\(artist) · \(title)" }
        return title
    }

    /// Genre string for on-screen metadata (excludes generic music-video tags).
    var musicGenreDisplay: String? {
        guard isMusicVideo else { return nil }
        let useful = genres.filter { g in
            let l = g.lowercased()
            return !l.contains("music video") && l != "music" && l != "musical"
        }
        guard !useful.isEmpty else { return nil }
        return useful.prefix(4).joined(separator: " · ")
    }
}
