import Foundation

/// Static manifest that claims TMDB items for specific channels. Built offline
/// by `scripts/channel-keyword-tuner` from curated exemplar lists plus their
/// TMDB recommendations/similar graph.
///
/// When an item's TMDB ID is in the manifest, the manifest adds the item to any
/// channel it lists (skipping keyword/genre matching). Channels that define
/// `yearRange` or `type` in channels.json still enforce those gates; channels
/// without them (e.g. REWATCHABLES) are not era-filtered. Items not in the
/// manifest fall through to rule-based filtering only.
///
/// Key format: "<mediaType>:<tmdbID>", e.g. "tv:1396" or "movie:12345".
struct ChannelMemberships: Codable {
    let version: Int
    let generated: String
    let items: [String: Entry]

    struct Entry: Codable {
        let channels: [Int]
        let source: String?
        let name: String?       // denormalized for dev tools; app ignores
        let mediaType: String?  // denormalized for dev tools; app ignores
        /// When set, the item is locked to this channel and must not appear
        /// anywhere else — even when other channels' rules would otherwise
        /// match. Used for TMDB-keyword-based routing (e.g. "stand-up comedy"
        /// → STAND-UP only). Set by the manifest builder via globalLocks.
        let exclusive: Int?
    }

    /// Look up channel claims for a given TMDB item. Returns nil if not claimed.
    func channels(forMediaType mediaType: String, tmdbID: String) -> [Int]? {
        items["\(mediaType):\(tmdbID)"]?.channels
    }

    /// Return the channel this item is exclusively locked to, if any.
    func exclusive(forMediaType mediaType: String, tmdbID: String) -> Int? {
        items["\(mediaType):\(tmdbID)"]?.exclusive
    }

    static let empty = ChannelMemberships(version: 0, generated: "", items: [:])
}

enum ChannelMembershipsLoader {
    /// Load the bundled manifest. Returns `.empty` if missing or unparseable so
    /// the app still works without it.
    static func loadBundled() -> ChannelMemberships {
        guard let url = Bundle.main.url(forResource: "channels-memberships", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(ChannelMemberships.self, from: data) else {
            return .empty
        }
        return manifest
    }
}
