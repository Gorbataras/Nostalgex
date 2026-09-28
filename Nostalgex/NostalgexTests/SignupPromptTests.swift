import XCTest
@testable import Nostalgex

/// Wire contract for the two update-emails signals. The weekly readout joins
/// `placement` here to `utm_content` on the website, so both sides must agree.
final class SignupAnalyticsEventTests: XCTestCase {

    func testQRShownSettingsWireContract() {
        let event = AnalyticsEvent.signupQRShown(placement: .settings, backend: .plex)
        XCTAssertEqual(event.name, "signup.qr.shown")
        XCTAssertEqual(event.parameters, ["placement": "settings", "backend": "plex"])
        XCTAssertNil(event.floatValue)
    }

    func testQRShownPostPlaybackWireContract() {
        let event = AnalyticsEvent.signupQRShown(placement: .postPlayback, backend: .jellyfin)
        XCTAssertEqual(event.name, "signup.qr.shown")
        XCTAssertEqual(event.parameters, ["placement": "post_playback", "backend": "jellyfin"])
    }

    func testPromptDismissedWireContract() {
        let expected: [(AnalyticsSignupDismissMethod, String)] = [
            (.button, "button"), (.back, "back"), (.timeout, "timeout"),
        ]
        for (method, wire) in expected {
            let event = AnalyticsEvent.signupPromptDismissed(method: method)
            XCTAssertEqual(event.name, "signup.prompt.dismissed")
            XCTAssertEqual(event.parameters, ["method": wire])
            XCTAssertNil(event.floatValue)
        }
    }

    /// QR targets carry the same placement value as the analytics signal, plus the
    /// fixed UTM set the website whitelists. Changing these breaks attribution.
    func testQRURLsCarryFixedUTMsAndPlacement() {
        XCTAssertEqual(
            SignupPrompt.url(for: .settings),
            "https://www.nostalgex.app/?utm_source=appletv&utm_medium=app&utm_campaign=qr_signup&utm_content=settings#signup"
        )
        XCTAssertEqual(
            SignupPrompt.url(for: .postPlayback),
            "https://www.nostalgex.app/?utm_source=appletv&utm_medium=app&utm_campaign=qr_signup&utm_content=post_playback#signup"
        )
        for placement in [AnalyticsSignupPlacement.settings, .postPlayback] {
            let comps = URLComponents(string: SignupPrompt.url(for: placement))
            XCTAssertEqual(comps?.fragment, "signup")
            let content = comps?.queryItems?.first { $0.name == "utm_content" }?.value
            XCTAssertEqual(content, placement.wireValue)
        }
    }
}

/// Gating rules for the one-time post-playback prompt.
final class SignupPromptGatingTests: XCTestCase {

    func testShouldShowOnlyForRealUnseenPlayback() {
        for isDemo in [false, true] {
            for seen in [false, true] {
                for playbackReady in [false, true] {
                    let expected = (isDemo, seen, playbackReady) == (false, false, true)
                    XCTAssertEqual(
                        SignupPrompt.shouldShowSignupPrompt(isDemo: isDemo, seen: seen, playbackReady: playbackReady),
                        expected,
                        "isDemo=\(isDemo) seen=\(seen) playbackReady=\(playbackReady)"
                    )
                }
            }
        }
    }

    /// Kept off the first minute of video, and the unattended card goes away.
    func testTimingConstantsKeepThePromptOffTheFirstMinute() {
        XCTAssertGreaterThanOrEqual(SignupPrompt.eligibilityDelay, 60)
        XCTAssertLessThanOrEqual(SignupPrompt.eligibilityDelay, 90)
        XCTAssertEqual(SignupPrompt.autoHideAfter, 20)
    }
}

/// End-to-end presentation on AppState with an isolated defaults suite, so the real
/// install's flag is never touched.
@MainActor
final class SignupPromptPresentationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var spy: SignupSpyAnalytics!

    override func setUp() async throws {
        suiteName = "SignupPromptPresentationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        spy = SignupSpyAnalytics()
        Analytics.configure(with: spy)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        Analytics.setDemoMode(false)
        Analytics.configure(with: NoOpAnalytics())
    }

    private func eligibleState() -> AppState {
        let state = AppState()
        state.signupPromptEligible = true
        return state
    }

    func testShownSetsFlagImmediatelyAndFiresShownOnce() {
        let state = eligibleState()
        XCTAssertTrue(state.presentSignupPromptIfReady(defaults: defaults))
        XCTAssertTrue(state.signupPromptVisible)
        XCTAssertTrue(defaults.bool(forKey: SignupPrompt.seenKey), "Flag must be set on show, not on dismiss")
        XCTAssertFalse(state.signupPromptEligible)
        XCTAssertEqual(spy.names, ["signup.qr.shown"])
        XCTAssertEqual(spy.calls.first?.parameters["placement"], "post_playback")
        state.resetSignupPrompt()
    }

    func testNeverShownTwicePerInstall() {
        let state = eligibleState()
        XCTAssertTrue(state.presentSignupPromptIfReady(defaults: defaults))
        state.dismissSignupPrompt(method: .button)

        // Same process, eligible again (e.g. a later playback): still no.
        state.signupPromptEligible = true
        XCTAssertFalse(state.presentSignupPromptIfReady(defaults: defaults))

        // A fresh AppState on the same defaults stands in for a relaunch.
        let relaunched = eligibleState()
        XCTAssertFalse(relaunched.presentSignupPromptIfReady(defaults: defaults))
        XCTAssertFalse(relaunched.signupPromptVisible)
        XCTAssertEqual(spy.names, ["signup.qr.shown", "signup.prompt.dismissed"])
    }

    func testDemoModeNeverShowsAndSendsNothing() {
        let state = eligibleState()
        state.isDemoMode = true
        XCTAssertFalse(state.presentSignupPromptIfReady(defaults: defaults))
        XCTAssertFalse(state.signupPromptVisible)
        XCTAssertFalse(defaults.bool(forKey: SignupPrompt.seenKey))
        XCTAssertTrue(spy.calls.isEmpty)
    }

    func testNotEligibleWithoutPlayback() {
        let state = AppState()
        XCTAssertFalse(state.presentSignupPromptIfReady(defaults: defaults))
        XCTAssertFalse(defaults.bool(forKey: SignupPrompt.seenKey))
    }

    /// Never over the full-screen player: it waits for the guide.
    func testNotShownOverFullScreenPlayer() {
        let state = eligibleState()
        state.isFullScreen = true
        XCTAssertFalse(state.presentSignupPromptIfReady(defaults: defaults))
        XCTAssertTrue(state.signupPromptEligible, "Stays eligible so the guide can show it later")
        XCTAssertFalse(defaults.bool(forKey: SignupPrompt.seenKey))
    }

    func testDismissMethodsAreReportedAndDismissIsIdempotent() {
        let state = eligibleState()
        state.presentSignupPromptIfReady(defaults: defaults)
        state.dismissSignupPrompt(method: .back)
        state.dismissSignupPrompt(method: .timeout)  // already gone: no second signal
        XCTAssertFalse(state.signupPromptVisible)
        XCTAssertEqual(spy.names, ["signup.qr.shown", "signup.prompt.dismissed"])
        XCTAssertEqual(spy.calls.last?.parameters["method"], "back")
    }

    func testSignupSignalsCarryNoFreeText() {
        let state = eligibleState()
        state.presentSignupPromptIfReady(defaults: defaults)
        state.dismissSignupPrompt(method: .timeout)
        let allowedKeys: Set<String> = ["placement", "backend", "method", "demo"]
        for call in spy.calls {
            XCTAssertTrue(Set(call.parameters.keys).isSubset(of: allowedKeys), "\(call.parameters)")
            XCTAssertEqual(call.parameters["demo"], "false")
        }
    }
}

private final class SignupSpyAnalytics: AnalyticsService, @unchecked Sendable {
    struct Call {
        let name: String
        let parameters: [String: String]
    }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }
    var names: [String] { calls.map(\.name) }
    func configure() {}
    func track(_ event: AnalyticsEvent, contextParameters: [String: String]) {
        var params = contextParameters
        for (key, value) in event.parameters { params[key] = value }
        lock.lock()
        _calls.append(Call(name: event.name, parameters: params))
        lock.unlock()
    }
}
