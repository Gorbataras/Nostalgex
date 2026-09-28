import Foundation
import SwiftUI

// MARK: - Collection categories (auto-classified during scan)

enum CollectionCategory: String, CaseIterable {
    case franchises, actors, custom

    var displayName: String {
        switch self {
        case .franchises: return "FRANCHISES"
        case .actors:     return "NOTABLE STARS"
        case .custom:     return "CUSTOM COLLECTIONS"
        }
    }

    var bundleID: String { "collections-\(rawValue)" }

    var bundleDescription: String {
        switch self {
        case .franchises: return "Movie series and sequel collections"
        case .actors:     return "Collections named after actors and directors"
        case .custom:     return "Your custom Plex collections"
        }
    }

    /// Channel ID range base (50 slots each). Static franchise presets use 100–106 in channels.json.
    var idBase: Int {
        switch self {
        case .franchises: return 220
        case .actors:     return 300
        case .custom:     return 240
        }
    }
}

// MARK: - Discovered collections (from Plex scan)

struct DiscoveredCollection: Identifiable {
    let id: String              // ratingKey or "trilogies"
    let title: String           // e.g. "BATMAN COLLECTION"
    let movieCount: Int
    let items: [PlexMediaItem]
    var enabled: Bool
    var matchedChannel: String? // name-similarity match to a static channel
    var contentOverlap: ContentOverlap? // content-aware: most items already claimed by another channel
    var category: CollectionCategory = .custom
}

/// Content-aware duplicate signal: most of a discovered Plex collection's items
/// are already claimed by an existing channel via the membership manifest.
struct ContentOverlap: Equatable {
    let channelID: Int
    let channelName: String
    let overlapCount: Int    // items in the Plex collection that the manifest claims for channelID
    let totalCount: Int      // total items in the Plex collection
    var percent: Int { totalCount > 0 ? Int((Double(overlapCount) / Double(totalCount) * 100).rounded()) : 0 }
}

// MARK: - Rule types

struct GenreRules {
    var include: [String] = []
    var requireAll: [String] = []
    var exclude: [String] = []
}

struct YearRange {
    var min: Int?
    var max: Int?
}

struct DurationRange {
    var min: Int? // minutes
    var max: Int? // minutes
}

struct BlockRatings {
    var ratings: [String]
    var blockBefore: Int? // hour 0-23
    var blockAfter: Int?  // hour 0-23
}

struct TimeRestrictions {
    var blockRatings: BlockRatings?
    var tvOnlyBefore: Int?   // hour 0-23: only show episodes before this hour
    var onlyAfterHour: Int?  // hour 0-23: channel pool is empty before this hour (prime time gate)
}

struct ChannelRules {
    var type: MediaType?
    var source: LibrarySource? // restrict pool to items from a specific library type (e.g. .musicVideo)
    var genres: GenreRules?
    var studios: [String]?
    var yearRange: YearRange?
    var contentRatings: [String]?
    var allowUnrated: Bool = false
    var ratingMin: Double?
    var durationRange: DurationRange?
    var watchedOnly: Bool = false
    var unwatchedOnly: Bool = false
    var rewatched: Bool = false // viewCount >= 3 (must match scripts/nostalgex-channel-filter.cjs)
    var titleContains: [String]? // matches if title contains any of these (case-insensitive)
    var titleExcludes: [String]? // excludes if title contains any of these (case-insensitive)
    var editorialOverrides: [String]? // exact title matches always included regardless of other rules
    var addedWithinDays: Int? // only items added to library within this many days
    var releasedWithinMonths: Int? // only items released within this many months of today
    // TMDB enrichment rules
    var keywords: [String]?              // match if item has ANY of these TMDB keywords
    var keywordsRequireAll: [String]?    // match if item has ALL of these TMDB keywords
    var keywordsExclude: [String]?       // exclude if item has ANY of these TMDB keywords
    var keywordsRequireAnyGenre: [String]? // when set, keyword match only counts if item also has ANY of these genres (cross-reference)
    var keywordGatedGenres: [String]?    // when genre match is to one of these, a keyword match is also required
    var networks: [String]?              // match if TV show airs on ANY of these networks
    var productionCompanies: [String]?   // match if produced by ANY of these companies
    // OMDb enrichment rules
    var imdbRatingMin: Double?           // IMDb rating threshold (authoritative vs Plex ratingMin)
    var imdbVotesMin: Int?               // Minimum IMDb vote count — filters out obscure high-rated items
    var rtScoreMin: Int?                 // Rotten Tomatoes critic score 0-100
    var metacriticMin: Int?              // Metacritic score 0-100
    var wonOscar: Bool = false           // Awards string contains "won" + "oscar" (case-insensitive)
    var manifestOnly: Bool = false       // membership comes ONLY from the TMDB manifest — no genre/title fallback (for keyword-precise channels like STAND-UP, ANIME)
}

// MARK: - Channel

struct Channel: Identifiable {
    let id: Int
    let number: Int
    let name: String
    let color: Color
    let category: String?
    let rules: ChannelRules?
    let timeRestrictions: TimeRestrictions?
    let minItems: Int
    /// Whether newly added titles premiere here at prime time.
    ///
    /// Exactly one channel should carry this. A new film usually sits in several pools,
    /// and when every one of them promoted it to the evening anchor it premiered on all
    /// of them at once: Point Break, added to five channels, aired on five channels
    /// simultaneously. A premiere is an event on one channel; everywhere else the title
    /// just enters the normal rotation.
    var isPremiereChannel: Bool = false
    var itemPool: [PlexMediaItem] = []
    var enabled: Bool = true

    /// Returns itemPool filtered for current time restrictions
    func filteredPool() -> [PlexMediaItem] {
        guard let tr = timeRestrictions else { return itemPool }
        let hour = Calendar.current.component(.hour, from: Date())
        var pool = itemPool

        // Block ratings (e.g. Late Night R-rated content before 8pm)
        if let br = tr.blockRatings {
            let isBlocked = (br.blockBefore.map { hour < $0 } ?? false)
                         || (br.blockAfter.map { hour >= $0 } ?? false)
            if isBlocked {
                let filtered = pool.filter { !br.ratings.contains($0.contentRating ?? "") }
                if filtered.count >= 2 { pool = filtered }
            }
        }

        // TV-only before hour (e.g. only episodes before 11 AM)
        if let tvBefore = tr.tvOnlyBefore, hour < tvBefore {
            let episodesOnly = pool.filter { $0.type == .episode }
            if episodesOnly.count >= 2 { pool = episodesOnly }
        }

        // Prime time gate: channel is unavailable before this hour
        if let afterHour = tr.onlyAfterHour, hour < afterHour {
            return []
        }

        return pool
    }
}

// MARK: - JSON config (Codable)

// MARK: - Exclusive rules (channel ownership)

struct ExclusiveRule {
    /// Channels allowed to own this content. Content matching this rule is
    /// blocked from every channel NOT in this list (e.g. anime -> [32, 60]).
    let channelIDs: [Int]
    let genres: [String]
    let titleContains: [String]
    let editorialTitles: [String]
    /// When true, any item the manifest claims for one of `channelIDs` is also
    /// owned by this rule — so manifest-claimed anime is blocked from other
    /// channels even when Plex tags it "Animation" instead of "Anime".
    let manifestExclusive: Bool

    func matches(_ item: PlexMediaItem) -> Bool {
        let titleLower = item.title.lowercased()
        // Plex's TMDB agent routinely stores films as "Elf (2003)". Every other
        // title comparison in the app strips that suffix, but this exact match
        // did not, so an editorialTitles entry of "Elf" silently failed and the
        // title leaked onto channels the rule was meant to lock it out of.
        // The web filter (scripts/nostalgex-channel-filter.cjs) already stripped
        // it, so the two surfaces disagreed about what was exclusive.
        let strippedLower = MusicTitleParser.stripYearSuffix(item.title).lowercased()

        // Editorial title match (exact, case-insensitive, year suffix ignored)
        if editorialTitles.contains(where: {
            let candidate = $0.lowercased()
            return titleLower == candidate || strippedLower == candidate
        }) {
            return true
        }

        // Title keyword match
        if !titleContains.isEmpty && titleContains.contains(where: { titleLower.contains($0.lowercased()) }) {
            return true
        }

        // Genre match
        if !genres.isEmpty {
            let genreMatch = item.genres.contains { genre in
                genres.contains { g in genre.lowercased().contains(g.lowercased()) }
            }
            if genreMatch { return true }
        }

        return false
    }
}

struct ExclusiveRuleJSON: Codable {
    // Back-compat: older configs/snapshots use a single `channelID`; newer ones
    // use `channelIDs`. At least one is present.
    let channelID: Int?
    let channelIDs: [Int]?
    let genres: [String]?
    let titleContains: [String]?
    let editorialTitles: [String]?
    let manifestExclusive: Bool?

    func toExclusiveRule() -> ExclusiveRule {
        ExclusiveRule(
            channelIDs: channelIDs ?? channelID.map { [$0] } ?? [],
            genres: genres ?? [],
            titleContains: titleContains ?? [],
            editorialTitles: editorialTitles ?? [],
            manifestExclusive: manifestExclusive ?? false
        )
    }
}

struct ChannelConfig: Codable {
    let version: Int
    let exclusiveRules: [ExclusiveRuleJSON]?
    let bundles: [ChannelBundleDefinition]?
    let channels: [ChannelDefinition]
}

struct ChannelDefinition: Codable {
    let id: Int
    let number: Int
    let name: String
    let colorHex: String
    let category: String?
    let minItems: Int?
    let isPremiereChannel: Bool?
    let rules: ChannelRulesJSON?
    let timeRestrictions: TimeRestrictionsJSON?

    func toChannel() -> Channel {
        Channel(
            id: id,
            number: number,
            name: name,
            color: Color(hex: colorHex),
            category: category,
            rules: rules?.toChannelRules(),
            timeRestrictions: timeRestrictions?.toTimeRestrictions(),
            minItems: minItems ?? 50,
            isPremiereChannel: isPremiereChannel ?? false
        )
    }
}

struct GenreRulesJSON: Codable {
    let include: [String]?
    let requireAll: [String]?
    let exclude: [String]?

    func toGenreRules() -> GenreRules {
        GenreRules(
            include: include ?? [],
            requireAll: requireAll ?? [],
            exclude: exclude ?? []
        )
    }
}

struct YearRangeJSON: Codable {
    let min: Int?
    let max: Int?

    func toYearRange() -> YearRange {
        YearRange(min: min, max: max)
    }
}

struct DurationRangeJSON: Codable {
    let min: Int?
    let max: Int?

    func toDurationRange() -> DurationRange {
        DurationRange(min: min, max: max)
    }
}

struct ChannelRulesJSON: Codable {
    let type: String?
    let source: String?
    let genres: GenreRulesJSON?
    let studios: [String]?
    let yearRange: YearRangeJSON?
    let contentRatings: [String]?
    let allowUnrated: Bool?
    let ratingMin: Double?
    let durationRange: DurationRangeJSON?
    let watchedOnly: Bool?
    let unwatchedOnly: Bool?
    let rewatched: Bool?
    let titleContains: [String]?
    let titleExcludes: [String]?
    let editorialOverrides: [String]?
    let addedWithinDays: Int?
    let releasedWithinMonths: Int?
    // TMDB enrichment rules
    let keywords: [String]?
    let keywordsRequireAll: [String]?
    let keywordsExclude: [String]?
    let keywordsRequireAnyGenre: [String]?
    let keywordGatedGenres: [String]?
    let networks: [String]?
    let productionCompanies: [String]?
    // OMDb enrichment rules
    let imdbRatingMin: Double?
    let imdbVotesMin: Int?
    let rtScoreMin: Int?
    let metacriticMin: Int?
    let wonOscar: Bool?
    let manifestOnly: Bool?

    func toChannelRules() -> ChannelRules {
        var mediaType: MediaType?
        if let t = type {
            mediaType = MediaType(rawValue: t)
        }
        return ChannelRules(
            type: mediaType,
            source: source.flatMap { LibrarySource(rawValue: $0) },
            genres: genres?.toGenreRules(),
            studios: studios,
            yearRange: yearRange?.toYearRange(),
            contentRatings: contentRatings,
            allowUnrated: allowUnrated ?? false,
            ratingMin: ratingMin,
            durationRange: durationRange?.toDurationRange(),
            watchedOnly: watchedOnly ?? false,
            unwatchedOnly: unwatchedOnly ?? false,
            rewatched: rewatched ?? false,
            titleContains: titleContains,
            titleExcludes: titleExcludes,
            editorialOverrides: editorialOverrides,
            addedWithinDays: addedWithinDays,
            releasedWithinMonths: releasedWithinMonths,
            keywords: keywords,
            keywordsRequireAll: keywordsRequireAll,
            keywordsExclude: keywordsExclude,
            keywordsRequireAnyGenre: keywordsRequireAnyGenre,
            keywordGatedGenres: keywordGatedGenres,
            networks: networks,
            productionCompanies: productionCompanies,
            imdbRatingMin: imdbRatingMin,
            imdbVotesMin: imdbVotesMin,
            rtScoreMin: rtScoreMin,
            metacriticMin: metacriticMin,
            wonOscar: wonOscar ?? false,
            manifestOnly: manifestOnly ?? false
        )
    }
}

struct BlockRatingsJSON: Codable {
    let ratings: [String]
    let blockBefore: Int?
    let blockAfter: Int?

    func toBlockRatings() -> BlockRatings {
        BlockRatings(ratings: ratings, blockBefore: blockBefore, blockAfter: blockAfter)
    }
}

struct TimeRestrictionsJSON: Codable {
    let blockRatings: BlockRatingsJSON?
    let tvOnlyBefore: Int?
    let onlyAfterHour: Int?

    func toTimeRestrictions() -> TimeRestrictions {
        TimeRestrictions(
            blockRatings: blockRatings?.toBlockRatings(),
            tvOnlyBefore: tvOnlyBefore,
            onlyAfterHour: onlyAfterHour
        )
    }
}

// MARK: - Channel config loading

struct ChannelConfigResult {
    let channels: [Channel]
    let bundles: [ChannelBundleDefinition]
    let exclusiveRules: [ExclusiveRule]
}

enum ChannelConfigLoader {

    /// Load channels and bundles from JSON data
    static func loadConfig(from data: Data) -> ChannelConfigResult? {
        guard let config = try? JSONDecoder().decode(ChannelConfig.self, from: data) else {
            return nil
        }
        return ChannelConfigResult(
            channels: config.channels.map { $0.toChannel() },
            bundles: config.bundles ?? [],
            exclusiveRules: (config.exclusiveRules ?? []).map { $0.toExclusiveRule() }
        )
    }

    /// Load channels from JSON data (backward compat)
    static func loadChannels(from data: Data) -> [Channel]? {
        return loadConfig(from: data)?.channels
    }

    /// Load from bundled channels.json fallback
    static func loadBundled() -> ChannelConfigResult {
        guard let url = Bundle.main.url(forResource: "channels", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let result = loadConfig(from: data) else {
            return ChannelConfigResult(channels: [], bundles: [], exclusiveRules: [])
        }
        return result
    }
}
