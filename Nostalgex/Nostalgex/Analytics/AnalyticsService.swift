import Foundation

/// Underlying transport. Kept small so the wrapper is a single indirection over one
/// SDK call — no new dependencies, no fan-out.
protocol AnalyticsService: Sendable {
    func configure()
    /// Send one event. Implementations must merge `contextParameters` alongside the
    /// event's own parameters and use `floatValue` when present.
    func track(_ event: AnalyticsEvent, contextParameters: [String: String])
}

/// Static facade every call site uses. Owns the current transport plus a small
/// "context" — parameters attached to every signal — so demo mode can be filtered
/// out on the dashboard without every event carrying the flag explicitly.
enum Analytics {
    private static let lock = NSLock()
    private static var service: AnalyticsService = NoOpAnalytics()
    private static var context: [String: String] = ["demo": "false"]

    /// Install the transport. Called once at launch from `NostalgexApp`.
    static func configure(with service: AnalyticsService) {
        lock.lock()
        self.service = service
        lock.unlock()
        service.configure()
    }

    /// Toggle the `demo=true|false` parameter that every signal carries. Called by
    /// `AppState.enterDemoMode()` / `disconnect()`. Anything with `demo=true` can be
    /// filtered out (or filtered *in*) on the TelemetryDeck dashboard.
    static func setDemoMode(_ isOn: Bool) {
        lock.lock()
        context["demo"] = isOn ? "true" : "false"
        lock.unlock()
    }

    /// Fire one signal. Context parameters are merged in by the transport so the
    /// wrapper never needs to build a per-event dictionary.
    static func track(_ event: AnalyticsEvent) {
        let ctx: [String: String] = {
            lock.lock(); defer { lock.unlock() }
            return context
        }()
        service.track(event, contextParameters: ctx)
    }
}
