import XCTest
@testable import Nostalgex

@MainActor
final class AppStateHydrationTests: XCTestCase {
    func testHydrateCredentialsIfNeeded_doesNotOverwriteInMemoryCredentials() {
        let state = AppState()
        state.serverURL = "https://example.com"
        state.token = "token"

        state.hydrateCredentialsIfNeeded()

        XCTAssertEqual(state.serverURL, "https://example.com")
        XCTAssertEqual(state.token, "token")
    }
}


@MainActor
final class SignInMarkerBackfillTests: XCTestCase {
    private let markerKey = AppState.hasHeldSignInMarkerKey

    override func setUp() { UserDefaults.standard.removeObject(forKey: markerKey) }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: markerKey) }

    // A device whose sign-in predates the marker must still get one, otherwise a later
    // keychain loss shows the connect screen with no explanation (seen on a TestFlight
    // device after a force quit).
    func testSuccessfulHydrationBackfillsTheMarker() async {
        let state = AppState()
        state.serverURL = "https://example.com"
        state.token = "token"

        await state.hydrateCredentialsWithRetry()

        XCTAssertTrue(UserDefaults.standard.bool(forKey: markerKey))
    }
}
