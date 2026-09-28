import CryptoKit
import Foundation
import os
import SwiftUI

// MARK: - On-disk format (v1)

/// One channel row: rules + optional list of `PlexMediaItem.id` (rating keys) to rebuild pools.
struct StoredChannel: Codable {
    let id: Int
    let number: Int
    let name: String
    let colorHex: String
    let category: String?
    let minItems: Int
    /// Optional so snapshots written before premieres were limited to one channel
    /// still decode; absent reads as false.
    let isPremiereChannel: Bool?
    let rules: ChannelRulesJSON?
    let timeRestrictions: TimeRestrictionsJSON?
    let enabled: Bool
    let itemRatingKeys: [String]
}

struct StoredDiscoveredCollection: Codable {
    let id: String
    let title: String
    let movieCount: Int
    let itemRatingKeys: [String]
    let enabled: Bool
    let matchedChannel: String?
    let categoryRaw: String
}

struct LibrarySnapshotV1: Codable {
    var schemaVersion: Int
    var credentialFingerprint: String
    /// Unix seconds when the snapshot was produced. Snapshot is valid for 24h
    /// rolling (not day-boundary) so a load at 6pm stays warm until 6pm next day,
    /// avoiding a forced rescan in the user's evening when UTC midnight crosses.
    var lastLoadAtUnix: Int
    var serverName: String
    var allItems: [PlexMediaItem]
    var channelConfigRows: [StoredChannel]
    var allChannelRows: [StoredChannel]
    var bundleDefinitions: [ChannelBundleDefinition]
    var enabledBundleIDList: [String]
    var exclusiveRuleJSON: [ExclusiveRuleJSON]
    var discoveredCollectionRows: [StoredDiscoveredCollection]
    /// Library change signature at the time of the scan (see LibraryChangeSignature).
    /// Optional so snapshots written before it existed still decode.
    var librarySignature: String? = nil
}

// MARK: - Store

enum LibrarySnapshotStore {
    /// How old library data may get before a background refresh runs. Was 24h; people add
    /// media during the day and expect it in tonight's guide, and the refresh is invisible
    /// (guide stays up, partial results are discarded), so the only real cost of 6h is four
    /// scans a day instead of one.
    static let refreshAfterSeconds = 6 * 3600
    /// Past this age a scan runs even if the library reports no change.
    static let forceRefreshAfterSeconds = 24 * 3600

    private static let fileName = "library_snapshot_v1.json"
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder = JSONDecoder()

    /// Keyed on WHICH library this is (server identity, and account where the backend has
    /// no server-side account notion), never on the session token. A token changes on every
    /// sign-in, and keying on it threw away a perfectly good snapshot each time, forcing a
    /// full rescan for no reason. A different account can only sign in after Disconnect,
    /// which clears the snapshot, so dropping the token leaks nothing.
    static func fingerprint(identity: String) -> String {
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static var directoryURL: URL? { LocalStore.rootDirectory }

    private static var fileURL: URL? {
        directoryURL?.appendingPathComponent(fileName)
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func save(
        identity: String,
        serverName: String,
        librarySignature: String?,
        lastLoadAtUnix: Int,
        allItems: [PlexMediaItem],
        channelConfigChannels: [Channel],
        allChannels: [Channel],
        bundles: [ChannelBundle],
        enabledBundleIDs: Set<String>,
        exclusiveRules: [ExclusiveRule],
        discoveredCollections: [DiscoveredCollection]
    ) throws {
        let fp = fingerprint(identity: identity)
        let configRows = channelConfigChannels.map { $0.toStoredChannel(includeItemKeys: false) }
        let visibleRows = allChannels.map { $0.toStoredChannel(includeItemKeys: true) }
        let defs = bundles.map {
            ChannelBundleDefinition(
                id: $0.id,
                name: $0.name,
                description: $0.description,
                channelIDs: $0.channelIDs,
                activeMonths: $0.activeMonths
            )
        }
        let snapshot = LibrarySnapshotV1(
            schemaVersion: 2,
            credentialFingerprint: fp,
            lastLoadAtUnix: lastLoadAtUnix,
            serverName: serverName,
            allItems: allItems,
            channelConfigRows: configRows,
            allChannelRows: visibleRows,
            bundleDefinitions: defs,
            enabledBundleIDList: Array(enabledBundleIDs).sorted(),
            exclusiveRuleJSON: exclusiveRules.map { $0.toExclusiveRuleJSON() },
            discoveredCollectionRows: discoveredCollections.map(StoredDiscoveredCollection.from),
            librarySignature: librarySignature
        )
        guard let url = fileURL else { throw SnapshotError.noApplicationSupport }
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
        InstallDiagnostics.note("snapshot: saved \(allItems.count) items, \(allChannels.count) channels to disk")
    }

  /// Loads snapshot when credentials match. `isStale` is true when older than 24h rolling window.
    static func loadSnapshot(identity: String) throws -> (snapshot: LibrarySnapshotV1, isStale: Bool)? {
        guard let url = fileURL else {
            InstallDiagnostics.note("snapshot: no Application Support directory")
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            InstallDiagnostics.note("snapshot: no file on disk at \(url.lastPathComponent)")
            return nil
        }
        let data = try Data(contentsOf: url)
        let snap: LibrarySnapshotV1
        do {
            snap = try decoder.decode(LibrarySnapshotV1.self, from: data)
        } catch {
            InstallDiagnostics.note("snapshot: decode failed (\(data.count) bytes): \(error)")
            throw error
        }
        guard snap.schemaVersion == 2 else {
            InstallDiagnostics.note("snapshot: schema mismatch (file=\(snap.schemaVersion), expected=2), clearing")
            clear()
            return nil
        }
        let fp = fingerprint(identity: identity)
        guard snap.credentialFingerprint == fp else {
            InstallDiagnostics.note("snapshot: credential fingerprint mismatch — stored=\(snap.credentialFingerprint.prefix(8))… current=\(fp.prefix(8))…")
            return nil
        }
        let now = Int(Date().timeIntervalSince1970)
        let ageSeconds = now - snap.lastLoadAtUnix
        let isStale = ageSeconds >= Self.refreshAfterSeconds
        let ageHours = ageSeconds / 3600
        if isStale {
            InstallDiagnostics.note("snapshot: \(ageHours)h old (>\(Self.refreshAfterSeconds / 3600)h), will refresh in background")
        } else {
            InstallDiagnostics.note("snapshot: hit, \(ageHours)h old, \(snap.allItems.count) items, \(snap.allChannelRows.count) channels")
        }
        return (snap, isStale)
    }

    static func loadIfValid(identity: String) throws -> LibrarySnapshotV1? {
        guard let loaded = try loadSnapshot(identity: identity), !loaded.isStale else { return nil }
        return loaded.snapshot
    }

    enum SnapshotError: Error {
        case noApplicationSupport
    }
}

// MARK: - Channel ↔ stored row

extension Channel {
    func toStoredChannel(includeItemKeys: Bool) -> StoredChannel {
        StoredChannel(
            id: id,
            number: number,
            name: name,
            colorHex: color.snapshotHexString,
            category: category,
            minItems: minItems,
            isPremiereChannel: isPremiereChannel,
            rules: rules?.toChannelRulesJSON(),
            timeRestrictions: timeRestrictions?.toTimeRestrictionsJSON(),
            enabled: enabled,
            itemRatingKeys: includeItemKeys ? itemPool.map(\.id) : []
        )
    }

    static func fromSnapshotRow(_ row: StoredChannel, itemLookup: [String: PlexMediaItem], includePool: Bool) -> Channel {
        let pool: [PlexMediaItem] = includePool
            ? row.itemRatingKeys.compactMap { itemLookup[$0] }
            : []
        return Channel(
            id: row.id,
            number: row.number,
            name: row.name,
            color: Color(hex: row.colorHex),
            category: row.category,
            rules: row.rules?.toChannelRules(),
            timeRestrictions: row.timeRestrictions?.toTimeRestrictions(),
            minItems: row.minItems,
            isPremiereChannel: row.isPremiereChannel ?? false,
            itemPool: pool,
            enabled: row.enabled
        )
    }
}

extension StoredDiscoveredCollection {
    static func from(_ collection: DiscoveredCollection) -> StoredDiscoveredCollection {
        StoredDiscoveredCollection(
            id: collection.id,
            title: collection.title,
            movieCount: collection.movieCount,
            itemRatingKeys: collection.items.map(\.id),
            enabled: collection.enabled,
            matchedChannel: collection.matchedChannel,
            categoryRaw: collection.category.rawValue
        )
    }

    func resolve(itemLookup: [String: PlexMediaItem]) -> DiscoveredCollection {
        let items = itemRatingKeys.compactMap { itemLookup[$0] }
        let category = CollectionCategory(rawValue: categoryRaw) ?? .custom
        return DiscoveredCollection(
            id: id,
            title: title,
            movieCount: movieCount,
            items: items,
            enabled: enabled,
            matchedChannel: matchedChannel,
            category: category
        )
    }
}
