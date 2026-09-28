import Foundation

protocol AnalyticsService: Sendable {
    func configure()
    func track(_ event: AnalyticsEvent)
}

enum Analytics {
    private static let lock = NSLock()
    private static var service: AnalyticsService = NoOpAnalytics()

    static func configure(with service: AnalyticsService) {
        lock.lock()
        self.service = service
        lock.unlock()
        service.configure()
    }

    static func track(_ event: AnalyticsEvent) {
        service.track(event)
    }
}
