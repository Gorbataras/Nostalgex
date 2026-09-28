import XCTest
@testable import Nostalgex

@MainActor
final class SignInLossDiagnosisTests: XCTestCase {

    // MARK: - Transient status classification

    func testKeychainNotReadyStatusesAreTransient() {
        XCTAssertTrue(KeychainService.isTransientLoadStatus(-25308))   // errSecInteractionNotAllowed
        XCTAssertTrue(KeychainService.isTransientLoadStatus(-34018))   // missing entitlement (simulator)
    }

    /// "Item not found" must NOT be transient: retrying it delays the connect screen for
    /// a user whose sign-in is genuinely gone, without ever finding anything.
    func testGoneAndSuccessStatusesAreNotTransient() {
        XCTAssertFalse(KeychainService.isTransientLoadStatus(-25300))  // errSecItemNotFound
        XCTAssertFalse(KeychainService.isTransientLoadStatus(0))
    }

    // MARK: - Diagnosis matrix

    /// No marker means fresh install or deliberate sign-out. Diagnosing those as data
    /// loss would show every new user a scary warning.
    func testNoMarkerProducesNoDiagnosis() {
        XCTAssertNil(AppState.signInLossDiagnosis(markerPresent: false, statuses: ["plex_token": -25300]))
    }

    /// Marker present + credentials gone is the bug happening; the token's status code
    /// must ride along so a report identifies the cause.
    func testMarkerWithLostTokenNamesTheStatusCode() {
        let diagnosis = AppState.signInLossDiagnosis(markerPresent: true, statuses: ["plex_token": -25300])
        XCTAssertNotNil(diagnosis)
        XCTAssertTrue(diagnosis!.contains("-25300"))
    }

    func testMarkerWithNoRecordedStatusStillDiagnoses() {
        let diagnosis = AppState.signInLossDiagnosis(markerPresent: true, statuses: [:])
        XCTAssertNotNil(diagnosis)
        XCTAssertTrue(diagnosis!.contains("?"))
    }
}
