import Foundation
import TelemetryDeck

struct TelemetryDeckAnalytics: AnalyticsService {
    let appID: String

    func configure() {
        guard !appID.isEmpty else { return }
        let config = TelemetryDeck.Config(appID: appID)
        TelemetryDeck.initialize(config: config)
    }

    func track(_ event: AnalyticsEvent, contextParameters: [String: String]) {
        guard !appID.isEmpty else { return }
        // Event parameters win over context on key collisions. Nothing in the current
        // context (only `demo`) collides with an event parameter today, but making the
        // precedence explicit avoids surprises if the context grows.
        var params = contextParameters
        for (key, value) in event.parameters {
            params[key] = value
        }
        if let floatValue = event.floatValue {
            TelemetryDeck.signal(event.name, parameters: params, floatValue: floatValue)
        } else if params.isEmpty {
            TelemetryDeck.signal(event.name)
        } else {
            TelemetryDeck.signal(event.name, parameters: params)
        }
    }
}
