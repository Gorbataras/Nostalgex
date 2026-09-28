import Foundation

enum AnalyticsEvent: Sendable {
    case plexConnectStarted
    case plexConnectCompleted(serverCount: Int)
    case plexConnectFailed(reason: String)
    case libraryLoadCompleted(channelCount: Int, itemCount: Int, background: Bool)
    case libraryLoadFailed(reason: String)
    case channelTuned(channelNumber: Int)
    case playbackStarted(channelNumber: Int)

    var name: String {
        switch self {
        case .plexConnectStarted: return "plex.connect.started"
        case .plexConnectCompleted: return "plex.connect.completed"
        case .plexConnectFailed: return "plex.connect.failed"
        case .libraryLoadCompleted: return "library.load.completed"
        case .libraryLoadFailed: return "library.load.failed"
        case .channelTuned: return "channel.tuned"
        case .playbackStarted: return "playback.started"
        }
    }

    var parameters: [String: String] {
        switch self {
        case .plexConnectStarted:
            return [:]
        case .plexConnectCompleted(let serverCount):
            return ["serverCount": String(serverCount)]
        case .plexConnectFailed(let reason):
            return ["reason": reason]
        case .libraryLoadCompleted(let channelCount, let itemCount, let background):
            return [
                "channelCount": String(channelCount),
                "itemCount": String(itemCount),
                "background": background ? "true" : "false",
            ]
        case .libraryLoadFailed(let reason):
            return ["reason": reason]
        case .channelTuned(let channelNumber):
            return ["channelNumber": String(channelNumber)]
        case .playbackStarted(let channelNumber):
            return ["channelNumber": String(channelNumber)]
        }
    }
}
