import Foundation

/// Keeps the watchdog's last verdicts where a person can read them.
///
/// The watchdog prints exactly why it gave up on a stream — whether the item reached
/// ready, how far the playhead moved, whether a frame decoded, segment and stall counts,
/// HLS error codes — but only to stdout, which nothing sees on a television in someone's
/// basement. Chasing a restart loop on a 4K film took a day of server probes that all came
/// back clean, because the one line that would have said "device" or "server" was never
/// retrievable. Now each verdict also goes to the unified log (Console.app sees it over the
/// network) and the last few are stored so Settings can show them. Logging only: nothing
/// here changes what the player does.
enum PlaybackDiagnostics {
    private static let key = "nostalgex_playback_verdicts"
    private static let keep = 5

    /// Record a watchdog or end-of-item decision. `outcome` is what the app did next.
    static func record(outcome: String, title: String, detail: String, defaults: UserDefaults = .standard) {
        let stamp = Self.clock.string(from: Date())
        let line = "\(stamp) \(outcome) — \"\(title)\" — \(detail)"
        InstallDiagnostics.note("WATCHDOG VERDICT: \(line)")
        var rows = defaults.stringArray(forKey: key) ?? []
        rows.insert(line, at: 0)
        if rows.count > keep { rows = Array(rows.prefix(keep)) }
        defaults.set(rows, forKey: key)
    }

    /// Newest first. Empty when playback has never been given up on.
    static func recent(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    /// The line Settings shows. Short enough to read from the couch, complete enough to
    /// tell a device problem from a server one.
    static func latestForSettings(defaults: UserDefaults = .standard) -> String? {
        recent(defaults: defaults).first
    }

    static func clear(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d HH:mm"; return f
    }()
}
