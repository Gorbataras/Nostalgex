import Foundation

/// Tracks a single playback session for one item on one channel.
/// Handles Plex timeline reporting (Now Playing) and scrobbling (mark watched).
/// Only fires API calls when a PlexAPIService is provided; Jellyfin/Emby/demo are no-ops.
///
/// Scrobble rule (hybrid gate):
///   1. Entry gate — tuned in during the first 15% of the program
///   2. Active time — accumulated ≥ 75% of total runtime while this tracker is active
/// Both gates must pass. Scrobble triggers as soon as threshold is crossed or on stop.
@MainActor
final class PlaybackTracker {

    // MARK: - Identity

    let sessionID = UUID().uuidString
    let item: PlexMediaItem
    /// Seconds into the program when the user tuned in.
    let seekOffset: Int

    // MARK: - Entry gate

    /// True if the user tuned in during the first 15% of the program.
    let eligibleEntry: Bool

    // MARK: - Watch clock

    private var activeWatchSeconds: Double = 0
    private var watchStart: Date? = nil

    // MARK: - State

    private(set) var scrobbled = false
    private var stopped = false

    // MARK: - 10-second timeline pulse

    private var timelineTimer: Timer?

    // MARK: - Plex API (nil = Jellyfin / Emby / demo)

    private let plexAPI: PlexAPIService?

    // MARK: - Init

    init(item: PlexMediaItem, seekOffset: Int, plexAPI: PlexAPIService?) {
        self.item = item
        self.seekOffset = seekOffset
        self.plexAPI = plexAPI

        let totalSec = Double(item.duration * 60)
        let entryFrac = totalSec > 0 ? Double(seekOffset) / totalSec : 1.0
        self.eligibleEntry = entryFrac <= 0.15

        print("[Tracker] \(sessionID.prefix(8)) START \"\(item.title)\" offset=\(seekOffset)s eligible=\(eligibleEntry)")
    }

    deinit {
        timelineTimer?.invalidate()
    }

    // MARK: - Lifecycle hooks

    /// Call when AVPlayer becomes .readyToPlay and begins playing.
    /// Idempotent — safe to call from retry / transcode-fallback paths for the same item.
    func onPlaybackReady() {
        guard !stopped else { return }
        if watchStart == nil {
            watchStart = Date()
        }
        if timelineTimer == nil {
            scheduleTimeline()
        }
        sendTimeline(state: "playing")
    }

    /// Call when the app enters the background.
    func onBackground() {
        guard !stopped else { return }
        accumulateTime()
        sendTimeline(state: "stopped")
        timelineTimer?.invalidate()
        timelineTimer = nil
    }

    /// Call when the app returns to the foreground.
    func onForeground() {
        guard !stopped else { return }
        watchStart = Date()
        scheduleTimeline()
        sendTimeline(state: "playing")
    }

    /// Finalize the session: flush accumulated time, send stopped, evaluate scrobble.
    /// Called before advancing, channel change, or disconnect.
    func stop() {
        guard !stopped else { return }
        stopped = true
        timelineTimer?.invalidate()
        timelineTimer = nil
        accumulateTime()
        sendTimeline(state: "stopped")
        evaluateAndScrobble()
        print("[Tracker] \(sessionID.prefix(8)) STOP \"\(item.title)\" watched=\(Int(activeWatchSeconds))s scrobbled=\(scrobbled)")
    }

    /// Tear down without reporting anything. Used when the user turns off Plex activity
    /// sync mid-program: clears the pulse timer so no further timeline/scrobble fires and,
    /// unlike `stop()`, sends no final "stopped" report — so no view-offset is written and
    /// the item never lands in Continue Watching.
    func abandon() {
        guard !stopped else { return }
        stopped = true
        timelineTimer?.invalidate()
        timelineTimer = nil
    }

    // MARK: - Private

    private func accumulateTime() {
        guard let start = watchStart else { return }
        activeWatchSeconds += Date().timeIntervalSince(start)
        watchStart = nil
    }

    private func scheduleTimeline() {
        timelineTimer?.invalidate()
        timelineTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onTimelineTick() }
        }
    }

    private func onTimelineTick() {
        guard !stopped else {
            timelineTimer?.invalidate()
            return
        }
        accumulateTime()
        watchStart = Date()
        let timeMs = (seekOffset * 1000) + Int(activeWatchSeconds * 1000)
        let durationMs = item.duration * 60 * 1000
        sendTimeline(state: "playing", timeMs: timeMs, durationMs: durationMs)
        evaluateAndScrobble()
    }

    private func currentTimeMs() -> Int {
        (seekOffset * 1000) + Int(activeWatchSeconds * 1000)
    }

    private func sendTimeline(state: String, timeMs: Int? = nil, durationMs: Int? = nil) {
        guard let api = plexAPI else { return }
        let t = timeMs ?? currentTimeMs()
        let d = durationMs ?? (item.duration * 60 * 1000)
        let rk = item.ratingKey
        let key = "/library/metadata/\(rk)"
        let sid = sessionID
        Task.detached {
            await api.reportTimeline(ratingKey: rk, key: key, state: state, timeMs: t, durationMs: d, sessionID: sid)
        }
    }

    private func evaluateAndScrobble() {
        guard eligibleEntry, !scrobbled else { return }
        let totalSec = Double(item.duration * 60)
        guard totalSec > 0, activeWatchSeconds / totalSec >= 0.75 else { return }
        scrobble()
    }

    private func scrobble() {
        guard !scrobbled, let api = plexAPI else { return }
        scrobbled = true
        let rk = item.ratingKey
        print("[Tracker] \(sessionID.prefix(8)) SCROBBLE \"\(item.title)\" rk=\(rk)")
        Task.detached {
            await api.scrobble(ratingKey: rk)
        }
    }
}
