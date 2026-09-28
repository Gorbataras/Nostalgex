import Foundation
import TVServices

// MARK: - Shared snapshot shape
//
// Mirrors `Nostalgex/Services/TopShelfSnapshot.swift`. Duplicated rather than
// shared because the app's sources live in a filesystem-synchronized group, and
// adding one file from it to a second target means hand-editing the project in
// a format the tooling cannot safely round-trip (tested: it produced a
// zero-byte project file).
//
// The duplication is deliberate and bounded: the two sides only ever agree on
// this JSON shape, the app is the sole writer and this is the sole reader. If
// you change one, change the other. The same documented-duplication pattern is
// already used for the Swift and JS channel filters.

private struct TopShelfSnapshot: Codable {
    struct Entry: Codable {
        let channelID: Int
        let channelNumber: Int
        let channelName: String
        let title: String
        let startUnix: Int
        let endUnix: Int
        let imageURL: String?
    }
    let generatedUnix: Int
    let entries: [Entry]
}

private enum TopShelfStore {
    static let appGroupID = "group.com.muellhaus.nostalgex"

    static func read() -> TopShelfSnapshot? {
        guard let container = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroupID),
              let data = try? Data(contentsOf: container.appendingPathComponent("Library/Caches/topshelf.json"))
        else { return nil }
        return try? JSONDecoder().decode(TopShelfSnapshot.self, from: data)
    }
}

/// Top Shelf content for Nostalgex: what is airing right now across the user's
/// channels, shown on the Apple TV home screen when Nostalgex sits in the top row.
///
/// This extension deliberately does almost nothing. It holds no credentials,
/// makes no network calls to the user's server, and contains no scheduling
/// logic. The app writes a small denormalised snapshot into the shared App Group
/// container whenever the lineup changes, and this reads it. That keeps every
/// scheduling decision in one place and means the extension cannot drift from
/// what the app is actually playing.
///
/// If the snapshot is missing (App Group not yet enabled, or the app has never
/// finished a library load) this returns nil and tvOS falls back to the static
/// Top Shelf image, which is the behaviour Nostalgex had before.
final class ContentProvider: TVTopShelfContentProvider {

    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        guard let snapshot = TopShelfStore.read() else {
            print("[Plex90] TOPSHELF: extension found no snapshot in the App Group container — falling back to the static image")
            return nil
        }

        let now = Int(Date().timeIntervalSince1970)
        // Only show programmes whose window actually contains now. A stale
        // snapshot then shows nothing rather than lying about what is on.
        let live = snapshot.entries.filter { $0.startUnix <= now && $0.endUnix > now }
        guard !live.isEmpty else {
            print("[Plex90] TOPSHELF: snapshot has \(snapshot.entries.count) entries (generated \(snapshot.generatedUnix)) but none are live right now — falling back to the static image")
            return nil
        }
        print("[Plex90] TOPSHELF: showing \(live.count) live entries")

        let items: [TVTopShelfSectionedItem] = live.map { entry in
            let item = TVTopShelfSectionedItem(identifier: "channel-\(entry.channelID)")
            item.title = "CH \(entry.channelNumber)  \(entry.channelName)"
            item.imageShape = .poster
            if let raw = entry.imageURL, let url = URL(string: raw) {
                item.setImageURL(url, for: .screenScale1x)
                item.setImageURL(url, for: .screenScale2x)
            }
            // Deep link straight to the channel. The app reads this on open.
            if let action = URL(string: "nostalgex://channel/\(entry.channelID)") {
                item.displayAction = TVTopShelfAction(url: action)
                item.playAction = TVTopShelfAction(url: action)
            }
            return item
        }

        let section = TVTopShelfItemCollection(items: items)
        section.title = "On Now"
        return TVTopShelfSectionedContent(sections: [section])
    }
}
