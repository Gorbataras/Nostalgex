import Foundation

enum TelemetryDeckConfig {
    /// App ID from TelemetryDeck dashboard → Apps → Nostalgex → App ID.
    /// Set via Info.plist (`TelemetryDeckAppID`) or `TELEMETRYDECK_APP_ID` env var.
    static let appID: String = value(forEnv: "TELEMETRYDECK_APP_ID", infoPlistKey: "TelemetryDeckAppID")

    static var isConfigured: Bool { !appID.isEmpty }

    private static func value(forEnv envKey: String, infoPlistKey: String) -> String {
        if let v = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String, !v.isEmpty {
            return v
        }
        if let v = ProcessInfo.processInfo.environment[envKey], !v.isEmpty {
            return v
        }
        return ""
    }
}
