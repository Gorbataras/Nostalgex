import Foundation
import TelemetryDeck

struct TelemetryDeckAnalytics: AnalyticsService {
    let appID: String

    func configure() {
        guard !appID.isEmpty else { return }
        let config = TelemetryDeck.Config(appID: appID)
        TelemetryDeck.initialize(config: config)
    }

    func track(_ event: AnalyticsEvent) {
        guard !appID.isEmpty else { return }
        let params = event.parameters
        if params.isEmpty {
            TelemetryDeck.signal(event.name)
        } else {
            TelemetryDeck.signal(event.name, parameters: params)
        }
    }
}
