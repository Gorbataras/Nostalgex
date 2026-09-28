import Foundation

/// Apple TV App Store URLs for Nostalgex (tvOS supports star ratings only — no written reviews).
enum AppStoreLink {
    static let appID = "6762563534"

    /// Opens the Nostalgex product page in the tvOS App Store.
    static var productPage: URL {
        URL(string: "https://apps.apple.com/app/id\(appID)")!
    }
}
