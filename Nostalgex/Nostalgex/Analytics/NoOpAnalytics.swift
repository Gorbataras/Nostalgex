import Foundation

struct NoOpAnalytics: AnalyticsService {
    func configure() {}
    func track(_ event: AnalyticsEvent, contextParameters: [String: String]) {}
}
