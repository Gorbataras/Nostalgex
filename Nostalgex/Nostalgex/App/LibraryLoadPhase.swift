import Foundation

/// High-level stages shown on the loading screen (step rail + headline).
enum LibraryLoadPhase: Int, CaseIterable, Comparable {
    case preparing = 0
    case scanningLibrary = 1
    case discoveringCollections = 2
    case enrichingMetadata = 3
    case enrichingMusic = 4
    case buildingChannels = 5
    case finishing = 6

    static func < (lhs: LibraryLoadPhase, rhs: LibraryLoadPhase) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .preparing: return "Lineup"
        case .scanningLibrary: return "Library"
        case .discoveringCollections: return "Collections"
        case .enrichingMetadata: return "Metadata"
        case .enrichingMusic: return "Music"
        case .buildingChannels: return "Channels"
        case .finishing: return "Ready"
        }
    }

    /// Primary headline (uppercase in UI).
    func headline(detail: String = "") -> String {
        let base: String
        switch self {
        case .preparing:
            base = detail.isEmpty ? "PREPARING LINEUP" : detail
        case .scanningLibrary:
            base = detail.isEmpty ? "SCANNING PLEX LIBRARY" : detail
        case .discoveringCollections:
            base = detail.isEmpty ? "DISCOVERING COLLECTIONS" : detail
        case .enrichingMetadata:
            base = detail.isEmpty ? "ENRICHING METADATA" : detail
        case .enrichingMusic:
            base = detail.isEmpty ? "ENRICHING MUSIC VIDEOS" : detail
        case .buildingChannels:
            base = detail.isEmpty ? "BUILDING CHANNELS" : detail
        case .finishing:
            base = "TUNING IN"
        }
        return base.uppercased()
    }

    /// Subtitle under the step rail.
    var phaseHint: String {
        switch self {
        case .preparing:
            return "Loading channel rules and bundles"
        case .scanningLibrary:
            return "Reading movies, shows, and music from your server"
        case .discoveringCollections:
            return "Finding smart collections in your library"
        case .enrichingMetadata:
            return "TMDB and OMDb power the genre and network channels"
        case .enrichingMusic:
            return "MusicBrainz for music video channels"
        case .buildingChannels:
            return "Matching your library to each channel"
        case .finishing:
            return "Almost there"
        }
    }

    /// Steps shown in the progress rail for this run.
    static func visibleSteps(includesCollections: Bool, includesMusic: Bool) -> [LibraryLoadPhase] {
        var steps: [LibraryLoadPhase] = [.preparing, .scanningLibrary]
        if includesCollections { steps.append(.discoveringCollections) }
        steps.append(.enrichingMetadata)
        if includesMusic { steps.append(.enrichingMusic) }
        steps.append(contentsOf: [.buildingChannels, .finishing])
        return steps
    }

    func index(in visibleSteps: [LibraryLoadPhase]) -> Int? {
        visibleSteps.firstIndex(of: self)
    }
}
