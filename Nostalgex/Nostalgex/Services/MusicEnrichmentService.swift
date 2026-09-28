import Foundation
import Observation

/// Enriches music-video items via MusicBrainz when Plex metadata is thin.
@Observable
@MainActor
final class MusicEnrichmentService {

    private(set) var cache: [String: MusicVideoEnrichment] = [:]
    var isEnriching = false
    var progress: Double = 0
    var enrichedCount = 0
    var totalToEnrich = 0

    private let musicBrainz = MusicBrainzService()
    private let cacheFileName = "music_video_enrichments.json"

    // MARK: - Public API

    func enrichment(for item: PlexMediaItem) -> MusicVideoEnrichment? {
        cache[item.ratingKey]
    }

    /// Plex-only genres are often just "Music Video" — treat as thin metadata.
    static func plexGenresAreThin(_ genres: [String]) -> Bool {
        let useful = genres.filter { g in
            let l = g.lowercased()
            return !l.contains("music video") && l != "music" && l != "musical"
        }
        return useful.isEmpty
    }

    func loadDiskCache() {
        guard let url = cacheFileURL(),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: MusicVideoEnrichment].self, from: data) else { return }
        cache = decoded
        print("[MusicEnrichment] Loaded \(decoded.count) cached music-video rows")
    }

    func enrichMusicVideos(_ items: [PlexMediaItem]) async {
        loadDiskCache()

        let candidates = items.filter { ($0.librarySource ?? .movie) == .musicVideo }
        guard !candidates.isEmpty else { return }

        var work: [PlexMediaItem] = []
        for item in candidates {
            if let cached = cache[item.ratingKey],
               cached.hasUsefulGenres || cached.artist != nil,
               Date().timeIntervalSince(cached.fetchedAt) < 60 * 60 * 24 * 90 {
                continue
            }
            work.append(item)
        }

        guard !work.isEmpty else {
            print("[MusicEnrichment] All \(candidates.count) music videos already cached")
            totalToEnrich = 0
            enrichedCount = 0
            isEnriching = false
            progress = 1
            return
        }

        totalToEnrich = work.count
        enrichedCount = 0
        progress = 0
        isEnriching = true
        print("[MusicEnrichment] Resolving \(totalToEnrich) music videos via MusicBrainz (~1/sec)")

        var updated = false
        for (index, item) in work.enumerated() {
            if let row = await resolve(item) {
                cache[item.ratingKey] = row
                updated = true
            }
            enrichedCount = index + 1
            progress = Double(enrichedCount) / Double(totalToEnrich)
            if index % 5 == 4 { await Task.yield() }
        }

        if updated { saveDiskCache() }

        let withArtist = cache.values.filter { ($0.artist ?? "").isEmpty == false }.count
        let withGenres = cache.values.filter(\.hasUsefulGenres).count
        print("[MusicEnrichment] Done — \(withArtist) with artist, \(withGenres)/\(cache.count) with mapped genres")
        isEnriching = false
        progress = 1
    }

    /// Re-apply disk cache to library + channels (e.g. after same-day snapshot restore).
    func applyCachedDisplayMetadata(allItems: inout [PlexMediaItem], allChannels: inout [Channel]) {
        loadDiskCache()
        allItems = itemsWithDisplayMetadata(allItems)
        allChannels = refreshChannelPools(allChannels, from: allItems)
    }

    // MARK: - Resolution

    private func resolve(_ item: PlexMediaItem) async -> MusicVideoEnrichment? {
        let parsed = MusicTitleParser.parse(item.title)
        let songTitle = parsed.song
        let artistHint = item.artist ?? parsed.artist
        let year = item.year

        do {
            if let match = try await musicBrainz.resolveRecording(title: songTitle, artist: artistHint, year: year) {
                return MusicVideoEnrichment(
                    ratingKey: item.ratingKey,
                    recordingTitle: match.recordingTitle,
                    artist: match.artist ?? artistHint,
                    musicBrainzID: match.mbid,
                    genres: mergeGenres(plex: item.genres, resolved: match.genres),
                    releaseYear: match.releaseYear,
                    fetchedAt: Date()
                )
            }
        } catch {
            print("[MusicEnrichment] MusicBrainz failed \(item.title): \(error)")
        }

        guard artistHint != nil || !Self.plexGenresAreThin(item.genres) else { return nil }

        return MusicVideoEnrichment(
            ratingKey: item.ratingKey,
            recordingTitle: songTitle,
            artist: artistHint,
            musicBrainzID: nil,
            genres: item.genres,
            releaseYear: nil,
            fetchedAt: Date()
        )
    }

    /// Apply cached MusicBrainz rows onto Plex items for UI and schedules.
    func itemsWithDisplayMetadata(_ items: [PlexMediaItem]) -> [PlexMediaItem] {
        items.map { item in
            guard let music = cache[item.ratingKey] else { return item }
            return item.applyingMusicEnrichment(music)
        }
    }

    /// Refresh channel pools so schedule entries show enriched titles/artists.
    func refreshChannelPools(_ channels: [Channel], from items: [PlexMediaItem]) -> [Channel] {
        let byKey = Dictionary(items.map { ($0.ratingKey, $0) }, uniquingKeysWith: { first, _ in first })
        return channels.map { ch in
            var copy = ch
            copy.itemPool = ch.itemPool.map { byKey[$0.ratingKey] ?? $0 }
            return copy
        }
    }

    private func mergeGenres(plex: [String], resolved: [String]) -> [String] {
        var out = plex
        for g in resolved {
            if !out.contains(where: { $0.caseInsensitiveCompare(g) == .orderedSame }) {
                out.append(g)
            }
        }
        return out
    }

    // MARK: - Persistence

    private func cacheFileURL() -> URL? {
        LocalStore.rootDirectory?.appendingPathComponent(cacheFileName)
    }

    private func saveDiskCache() {
        guard let url = cacheFileURL(),
              let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
