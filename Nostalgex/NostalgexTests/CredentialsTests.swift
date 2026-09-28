import XCTest
@testable import Nostalgex

@MainActor
final class CredentialsTests: XCTestCase {
    private final class InMemoryStore: Nostalgex.CredentialStoring {
        var values: [String: String] = [:]
        /// Set to simulate a store that accepts a write it cannot return, which is the
        /// device failure the persistence check exists to catch.
        var failWrites = false

        @discardableResult
        func save(key: String, value: String) -> Bool {
            guard !failWrites else { return false }
            values[key] = value
            return true
        }
        func load(key: String) -> String? { values[key] }
        func delete(key: String) { values[key] = nil }
    }

    func testSaveCredentials_flagsWhenTheStoreCannotPersist() {
        let store = InMemoryStore()
        store.failWrites = true
        let state = AppState(credentialStore: store)

        state.serverURL = "https://my-plex"
        state.token = "abc123"
        state.saveCredentials()

        XCTAssertFalse(
            state.credentialsArePersistent,
            "A store that refuses the write must leave the session marked non-durable"
        )
    }

    func testSaveCredentials_marksPersistentOnSuccess() {
        let store = InMemoryStore()
        let state = AppState(credentialStore: store)

        state.serverURL = "https://my-plex"
        state.token = "abc123"
        state.saveCredentials()

        XCTAssertTrue(state.credentialsArePersistent)
    }

    func testSaveAndLoadCredentials_roundTrip() {
        let store = InMemoryStore()
        let state = AppState(credentialStore: store)

        state.serverURL = "https://my-plex"
        state.token = "abc123"
        state.saveCredentials()

        // New app state instance should load from the same store.
        let rehydrated = AppState(credentialStore: store)
        rehydrated.loadCredentials()

        XCTAssertEqual(rehydrated.serverURL, "https://my-plex")
        XCTAssertEqual(rehydrated.token, "abc123")
    }

    func testClearCredentials_deletesStoredValues() {
        let store = InMemoryStore()
        let state = AppState(credentialStore: store)

        state.serverURL = "https://my-plex"
        state.token = "abc123"
        state.saveCredentials()

        state.clearCredentials()
        XCTAssertFalse(state.hasCredentials)

        let rehydrated = AppState(credentialStore: store)
        rehydrated.loadCredentials()
        XCTAssertEqual(rehydrated.serverURL, "")
        XCTAssertEqual(rehydrated.token, "")
    }

    func testSaveCredentials_stripsTrailingSlashesOnServerURL() {
        let store = InMemoryStore()
        let state = AppState(credentialStore: store)
        state.serverURL = "http://192.168.1.10:32400/"
        state.token = "t"
        state.saveCredentials()

        let rehydrated = AppState(credentialStore: store)
        rehydrated.loadCredentials()
        XCTAssertEqual(rehydrated.serverURL, "http://192.168.1.10:32400")
    }

    func testSaveCredentials_overwritesExistingValues() {
        let store = InMemoryStore()
        let state = AppState(credentialStore: store)

        state.serverURL = "https://one"
        state.token = "t1"
        state.saveCredentials()

        state.serverURL = "https://two"
        state.token = "t2"
        state.saveCredentials()

        let rehydrated = AppState(credentialStore: store)
        rehydrated.loadCredentials()
        XCTAssertEqual(rehydrated.serverURL, "https://two")
        XCTAssertEqual(rehydrated.token, "t2")
    }
}

