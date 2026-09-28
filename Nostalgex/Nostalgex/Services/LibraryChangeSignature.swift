import Foundation

/// A cheap fingerprint of "has the library changed since we last scanned it". Plex stamps
/// every section with scannedAt / updatedAt / contentChangedAt, so one small request per
/// server answers the question the 6-hour timer used to answer with a full rescan.
enum LibraryChangeSignature {
    /// Built from `updatedAt` (section metadata) and `contentChangedAt` (Plex's per-section
    /// change counter, not a timestamp), which move only when something actually changed.
    /// `scannedAt` is deliberately left out: Plex's scheduled scans bump it every time even
    /// when they find nothing, which would make every 6h check look like a change.
    /// Nil when a section carries neither field (Jellyfin and Emby sections don't), so the
    /// caller cannot claim "unchanged" about a library it cannot actually observe.
    static func signature(serverID: String, sections: [PlexSection]) -> String? {
        var parts: [String] = []
        for s in sections {
            guard s.updatedAt != nil || s.contentChangedAt != nil else { return nil }
            parts.append("\(s.key)=u\(s.updatedAt ?? 0)/c\(s.contentChangedAt ?? 0)")
        }
        guard !parts.isEmpty else { return nil }
        return "\(serverID):" + parts.sorted().joined(separator: ",")
    }

    static func combine(_ perServer: [String]) -> String {
        perServer.sorted().joined(separator: ";")
    }

    /// Skip the scan only when the library is provably unchanged AND the hard cap hasn't
    /// passed. The cap exists because section timestamps don't move for everything the
    /// guide cares about (watch counts, for one), so "unchanged" is allowed to stand in for
    /// a scan for at most a day.
    static func shouldSkipRefresh(ageSeconds: Int, stored: String?, current: String?, hardCapSeconds: Int) -> Bool {
        guard ageSeconds < hardCapSeconds, let stored, let current else { return false }
        return stored == current
    }
}
