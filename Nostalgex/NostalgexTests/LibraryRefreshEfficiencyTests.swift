import XCTest
@testable import Nostalgex

/// Two rules: a re-sign-in must not throw away a good library snapshot, and a timed
/// refresh must ask the server whether anything changed before it rescans.
@MainActor
final class LibraryRefreshEfficiencyTests: XCTestCase {
    private final class InMemoryStore: Nostalgex.CredentialStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        @discardableResult
        func save(key: String, value: String) -> Bool { values[key] = value; return true }
        func load(key: String) -> String? { values[key] }
        func delete(key: String) { values[key] = nil }
    }

    private func server(_ id: String) -> AppState.ServerRef {
        AppState.ServerRef(machineIdentifier: id, name: id, baseURL: "https://\(id):32400", owned: true, token: "t-\(id)")
    }

    // MARK: - Fingerprint ignores the session token

    func testPlexFingerprintSurvivesANewToken() {
        let state = AppState(credentialStore: InMemoryStore())
        state.backendKind = .plex
        state.selectedServers = [server("den")]
        state.token = "token-A"
        let before = state.scheduleCredentialFingerprint
        state.token = "token-B"
        XCTAssertEqual(state.scheduleCredentialFingerprint, before, "a fresh sign-in is the same library; the snapshot and schedules must survive it")
    }

    func testFingerprintChangesWithTheServerSet() {
        let state = AppState(credentialStore: InMemoryStore())
        state.backendKind = .plex
        state.selectedServers = [server("den")]
        let one = state.scheduleCredentialFingerprint
        state.selectedServers = [server("den"), server("loft")]
        XCTAssertNotEqual(state.scheduleCredentialFingerprint, one)
    }

    func testJellyfinFingerprintIsPerUserNotPerToken() {
        let state = AppState(credentialStore: InMemoryStore())
        state.backendKind = .jellyfin
        state.serverURL = "https://jf.local"
        state.jellyfinUserId = "u1"
        state.token = "a"
        let before = state.scheduleCredentialFingerprint
        state.token = "b"
        XCTAssertEqual(state.scheduleCredentialFingerprint, before)
        state.jellyfinUserId = "u2"
        XCTAssertNotEqual(state.scheduleCredentialFingerprint, before)
    }

    // MARK: - Change signature

    private func section(_ key: String, scanned: Int?, updated: Int?, changed: Int?) -> PlexSection {
        PlexSection(key: key, title: key, type: "movie", scannedAt: scanned, updatedAt: updated, contentChangedAt: changed)
    }

    func testSignatureIsOrderIndependentAndTracksRealChanges() {
        let a = LibraryChangeSignature.signature(serverID: "s", sections: [section("1", scanned: 10, updated: 20, changed: 5), section("2", scanned: 7, updated: 3, changed: nil)])
        let b = LibraryChangeSignature.signature(serverID: "s", sections: [section("2", scanned: 7, updated: 3, changed: nil), section("1", scanned: 10, updated: 20, changed: 5)])
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "s:1=u20/c5,2=u3/c0")
        let contentChanged = LibraryChangeSignature.signature(serverID: "s", sections: [section("1", scanned: 10, updated: 20, changed: 99), section("2", scanned: 7, updated: 3, changed: nil)])
        XCTAssertNotEqual(a, contentChanged)
    }

    // Live server check (2026-09-15): Plex's scheduled scans bump scannedAt on every run
    // whether or not anything changed. If it were in the signature, the skip would never fire.
    func testRoutineRescanDoesNotChangeTheSignature() {
        let before = LibraryChangeSignature.signature(serverID: "s", sections: [section("1", scanned: 1789527297, updated: 1789169420, changed: 2339733)])
        let after = LibraryChangeSignature.signature(serverID: "s", sections: [section("1", scanned: 1789530897, updated: 1789169420, changed: 2339733)])
        XCTAssertEqual(before, after)
    }

    // Jellyfin/Emby sections carry no stamps. Claiming "unchanged" about them would freeze
    // the guide, so the signature must refuse rather than return something constant.
    func testSectionsWithoutStampsProduceNoSignature() {
        XCTAssertNil(LibraryChangeSignature.signature(serverID: "s", sections: [PlexSection(key: "1", title: "Movies", type: "movie")]))
        XCTAssertNil(LibraryChangeSignature.signature(serverID: "s", sections: [section("1", scanned: 5, updated: nil, changed: nil)]), "scannedAt alone is not evidence of anything")
        XCTAssertNil(LibraryChangeSignature.signature(serverID: "s", sections: []))
    }

    // MARK: - Skip decision

    func testSkipOnlyWhenUnchangedAndUnderTheCap() {
        let cap = 24 * 3600
        XCTAssertTrue(LibraryChangeSignature.shouldSkipRefresh(ageSeconds: 7 * 3600, stored: "x", current: "x", hardCapSeconds: cap))
        XCTAssertFalse(LibraryChangeSignature.shouldSkipRefresh(ageSeconds: 7 * 3600, stored: "x", current: "y", hardCapSeconds: cap), "library changed")
        XCTAssertFalse(LibraryChangeSignature.shouldSkipRefresh(ageSeconds: 25 * 3600, stored: "x", current: "x", hardCapSeconds: cap), "hard cap: watch counts etc. do not move the stamps")
        XCTAssertFalse(LibraryChangeSignature.shouldSkipRefresh(ageSeconds: 7 * 3600, stored: nil, current: "x", hardCapSeconds: cap), "no baseline")
        XCTAssertFalse(LibraryChangeSignature.shouldSkipRefresh(ageSeconds: 7 * 3600, stored: "x", current: nil, hardCapSeconds: cap), "server unreachable or backend can't say")
    }
}
