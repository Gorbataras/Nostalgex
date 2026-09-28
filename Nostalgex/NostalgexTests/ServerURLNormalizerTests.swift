import XCTest
@testable import Nostalgex

// Jellyfin / Emby addresses as people actually type them on a TV keyboard.
@MainActor
final class ServerURLNormalizerTests: XCTestCase {
    func testBareIPTriesTheDefaultPortFirst() {
        XCTAssertEqual(ServerURLNormalizer.candidates("192.168.1.10"),
                       ["http://192.168.1.10:8096", "http://192.168.1.10"])
    }

    func testPastedWebUIAddressIsCleanedUp() {
        XCTAssertEqual(ServerURLNormalizer.candidates("http://192.168.1.10:8096/web/#/home"),
                       ["http://192.168.1.10:8096"])
        XCTAssertEqual(ServerURLNormalizer.candidates("http://nas.local:8096/web/index.html#!/home"),
                       ["http://nas.local:8096"])
    }

    func testTypedPortHttpsAndProxyPathAreKept() {
        XCTAssertEqual(ServerURLNormalizer.candidates("http://10.0.0.5:8920"), ["http://10.0.0.5:8920"])
        XCTAssertEqual(ServerURLNormalizer.candidates("https://media.example.com"), ["https://media.example.com"])
        XCTAssertEqual(ServerURLNormalizer.candidates("https://example.com/jellyfin/"), ["https://example.com/jellyfin"])
    }

    func testWhitespaceCaseAndTrailingSlash() {
        XCTAssertEqual(ServerURLNormalizer.normalize("  HTTP://NAS.Local:8096/ "), "http://nas.local:8096")
        XCTAssertEqual(ServerURLNormalizer.normalize("   "), "")
    }

    func testOnlyWrongPlaceErrorsMoveOnToTheNextCandidate() {
        XCTAssertTrue(AppState.isWrongPlaceError(URLError(.cannotConnectToHost)))
        XCTAssertTrue(AppState.isWrongPlaceError(PlexAPIService.APIError.httpFailure(statusCode: 404)))
        XCTAssertTrue(AppState.isWrongPlaceError(PlexAPIService.APIError.receivedMarkupInsteadOfJSON(statusCode: 200)))
        XCTAssertFalse(AppState.isWrongPlaceError(PlexAPIService.APIError.unauthorized), "a wrong password is a real answer")
        XCTAssertFalse(AppState.isWrongPlaceError(URLError(.timedOut)), "a dead address should fail once, not twice")
    }

    func testFallbackUsesTheAddressThatAnswered() async throws {
        let (url, value) = try await AppState.tryServerCandidates("192.168.1.10") { candidate -> String in
            if candidate.hasSuffix(":8096") { throw URLError(.cannotConnectToHost) }
            return "ok"
        }
        XCTAssertEqual(url, "http://192.168.1.10")
        XCTAssertEqual(value, "ok")
    }

    func testSignInTimeoutIsShort() {
        XCTAssertEqual(SignInRequest.timeout, 15)
        XCTAssertTrue(SignInRequest.looksLikeMarkup(Data("  <!DOCTYPE html>".utf8)))
        XCTAssertFalse(SignInRequest.looksLikeMarkup(Data("{\"AccessToken\":\"x\"}".utf8)))
    }
}

// "Make sure Quick Connect is enabled" was shown even when the address was wrong.
@MainActor
final class QuickConnectFailureMessageTests: XCTestCase {
    func testUnreachableServerGetsTheNetworkMessageNotTheEnableItMessage() {
        let m = AppState.quickConnectFailureMessage(URLError(.cannotConnectToHost))
        XCTAssertTrue(m.contains("8096"), m)
        XCTAssertFalse(m.contains("Quick Connect is off"))
    }

    func testDisabledQuickConnectSaysSo() {
        XCTAssertTrue(AppState.quickConnectFailureMessage(PlexAPIService.APIError.unauthorized).contains("Quick Connect is off"))
    }

    func testWrongPlaceSaysItIsNotJellyfin() {
        XCTAssertTrue(AppState.quickConnectFailureMessage(PlexAPIService.APIError.httpFailure(statusCode: 404)).contains("isn't Jellyfin"))
    }

    func testNoEmDashes() {
        for e: Error in [URLError(.timedOut), PlexAPIService.APIError.unauthorized, PlexAPIService.APIError.invalidResponse] {
            XCTAssertFalse(AppState.quickConnectFailureMessage(e).contains("\u{2014}"))
        }
    }
}
