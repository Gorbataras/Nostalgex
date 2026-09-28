import XCTest
@testable import Nostalgex

// MARK: - Classifier (one table drives both the analytics reason and the message)

@MainActor
final class ConnectFailureClassifierTests: XCTestCase {

    private func reason(_ error: Error, stage: ConnectFailureStage = .signIn) -> AnalyticsConnectFailureReason {
        ConnectFailureClassifier.classify(error, backendName: "Jellyfin", stage: stage).reason
    }

    func testTransportErrorsMapToFixedReasons() {
        let table: [(URLError.Code, AnalyticsConnectFailureReason)] = [
            (.appTransportSecurityRequiresSecureConnection, .atsBlockedHTTP),
            (.cannotFindHost, .dnsNotFound),
            (.dnsLookupFailed, .dnsNotFound),
            (.cannotConnectToHost, .connectionRefused),
            (.timedOut, .timeout),
            (.notConnectedToInternet, .offline),
            (.networkConnectionLost, .offline),
            (.serverCertificateUntrusted, .tlsUntrustedCert),
            (.serverCertificateHasBadDate, .tlsUntrustedCert),
            (.serverCertificateHasUnknownRoot, .tlsUntrustedCert),
            (.serverCertificateNotYetValid, .tlsUntrustedCert),
            (.secureConnectionFailed, .tlsFailed),
            (.badURL, .urlInvalid),
            (.unsupportedURL, .urlInvalid),
            (.badServerResponse, .invalidResponse),
            (.resourceUnavailable, .other),
        ]
        for (code, expected) in table {
            let failure = ConnectFailureClassifier.classify(URLError(code), backendName: "Emby")
            XCTAssertEqual(failure.reason, expected, "\(code)")
            XCTAssertEqual(failure.errorCode, code.rawValue, "errorCode must be the numeric URLError code for \(code)")
        }
    }

    func testHTTPAndResponseShapeErrors() {
        typealias E = PlexAPIService.APIError
        XCTAssertEqual(reason(E.unauthorized), .authInvalidCredentials)
        XCTAssertEqual(reason(E.httpFailure(statusCode: 401)), .authInvalidCredentials)
        XCTAssertEqual(reason(E.httpFailure(statusCode: 403)), .authInvalidCredentials)
        XCTAssertEqual(reason(E.httpFailure(statusCode: 404)), .httpNotFound)
        XCTAssertEqual(reason(E.httpFailure(statusCode: 429)), .rateLimited)
        XCTAssertEqual(reason(E.httpFailure(statusCode: 405)), .httpClientError)
        XCTAssertEqual(reason(E.httpFailure(statusCode: 500)), .httpServerError)
        XCTAssertEqual(reason(E.httpFailure(statusCode: 502)), .httpServerError)
        XCTAssertEqual(reason(E.receivedMarkupInsteadOfJSON(statusCode: 200)), .markupResponse)
        XCTAssertEqual(reason(E.invalidResponse), .invalidResponse)
        XCTAssertEqual(ConnectFailureClassifier.classify(E.httpFailure(statusCode: 502), backendName: "Emby").errorCode, 502)
        XCTAssertNil(ConnectFailureClassifier.classify(E.unauthorized, backendName: "Emby").errorCode)
    }

    func testDecodeErrorIsInvalidResponseAndUnknownIsOther() throws {
        struct Wanted: Decodable { let AccessToken: String }
        let decodeError: Error
        do { _ = try JSONDecoder().decode(Wanted.self, from: Data("{}".utf8)); return XCTFail("should throw") }
        catch { decodeError = error }
        XCTAssertEqual(reason(decodeError), .invalidResponse)
        XCTAssertEqual(reason(NSError(domain: "x", code: 1)), .other)
    }

    func testURLErrorWrappedInNSErrorIsUnwrapped() {
        let wrapped = NSError(domain: "wrapper", code: 7, userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)])
        XCTAssertEqual(reason(wrapped), .timeout)
    }

    func testQuickConnectSplitsDisabledFromUnreachable() {
        XCTAssertEqual(reason(PlexAPIService.APIError.unauthorized, stage: .quickConnectStart), .quickConnectDisabled)
        XCTAssertEqual(reason(PlexAPIService.APIError.httpFailure(statusCode: 403), stage: .quickConnectStart), .quickConnectDisabled)
        XCTAssertEqual(reason(URLError(.cannotConnectToHost), stage: .quickConnectStart), .quickConnectUnreachable)
        XCTAssertEqual(reason(URLError(.timedOut), stage: .quickConnectStart), .quickConnectUnreachable)
        // A wrong path is not "disabled".
        XCTAssertEqual(reason(PlexAPIService.APIError.httpFailure(statusCode: 404), stage: .quickConnectStart), .httpNotFound)

        let disabled = ConnectFailureClassifier.classify(PlexAPIService.APIError.unauthorized, backendName: "Jellyfin", stage: .quickConnectStart)
        XCTAssertTrue(disabled.message.contains("Quick Connect is off"), disabled.message)
        // Unreachable keeps the precise transport message, not a vague "make sure it's enabled".
        let refused = ConnectFailureClassifier.classify(URLError(.cannotConnectToHost), backendName: "Jellyfin", stage: .quickConnectStart)
        XCTAssertTrue(refused.message.contains("8096"), refused.message)
        XCTAssertEqual(refused.errorCode, URLError.Code.cannotConnectToHost.rawValue)
    }

    func testPlexDiscoveryStageAlwaysReportsDiscoveryFailed() {
        let f = ConnectFailureClassifier.classify(URLError(.timedOut), backendName: "Plex", stage: .plexDiscovery)
        XCTAssertEqual(f.reason, .plexDiscoveryFailed)
        XCTAssertEqual(f.errorCode, URLError.Code.timedOut.rawValue)
    }

    func testWrongPathAndWrongPasswordReadDifferently() {
        let wrongPassword = AppState.serverUnreachableMessage(PlexAPIService.APIError.unauthorized, backend: "Jellyfin")
        let wrongPath = AppState.serverUnreachableMessage(PlexAPIService.APIError.httpFailure(statusCode: 404), backend: "Jellyfin")
        let webPage = AppState.serverUnreachableMessage(PlexAPIService.APIError.receivedMarkupInsteadOfJSON(statusCode: 200), backend: "Jellyfin")
        XCTAssertEqual(wrongPassword, "Incorrect username or password.")
        XCTAssertTrue(wrongPath.contains("/web"), wrongPath)
        XCTAssertTrue(webPage.contains("web page"), webPage)
    }

    func testServerUnreachableMessageIsTheClassifierMessage() {
        for error: Error in [URLError(.cannotConnectToHost), URLError(.timedOut), PlexAPIService.APIError.httpFailure(statusCode: 500)] {
            XCTAssertEqual(AppState.serverUnreachableMessage(error, backend: "Emby"),
                           ConnectFailureClassifier.classify(error, backendName: "Emby").message)
        }
    }

    /// Copy rules: short, human, no em dashes, never the old "fixed in 1.0.22" (the ATS
    /// change is already in 1.0.21).
    func testEveryMessageFollowsTheCopyRules() {
        for reason in AnalyticsConnectFailureReason.allCases {
            for code in [nil, 500] as [Int?] {
                let m = ConnectFailureClassifier.message(for: reason, backendName: "Jellyfin", errorCode: code)
                XCTAssertFalse(m.isEmpty, "\(reason)")
                XCTAssertFalse(m.contains("\u{2014}"), "em dash in \(reason): \(m)")
                XCTAssertFalse(m.contains("1.0.22"), "\(reason): \(m)")
                XCTAssertLessThan(m.count, 160, "\(reason) message is too long: \(m)")
            }
        }
    }

    func testWireValuesAreSnakeCaseAndUnique() {
        let values = AnalyticsConnectFailureReason.allCases.map(\.wireValue)
        XCTAssertEqual(Set(values).count, values.count)
        for v in values {
            XCTAssertNotNil(v.range(of: "^[a-z0-9_]+$", options: .regularExpression), v)
        }
    }

    func testPINMessagesComeFromTheSameClassification() {
        XCTAssertTrue(AppState.pinRequestFailureMessage(PlexAPIService.APIError.httpFailure(statusCode: 400)).contains("HTTP 400"))
        XCTAssertTrue(AppState.pinRequestFailureMessage(URLError(.dataNotAllowed)).contains("No internet"))
    }
}

// MARK: - URL normalization (Jellyfin / Emby)

final class ServerURLNormalizerTests: XCTestCase {

    func testNormalizationTable() {
        let table: [(typed: String, expected: [String])] = [
            // Bare IP: Jellyfin's default port first, portless second.
            ("192.168.1.10", ["http://192.168.1.10:8096", "http://192.168.1.10"]),
            // IP with the port: exactly what was typed.
            ("192.168.1.10:8096", ["http://192.168.1.10:8096"]),
            ("http://192.168.1.10:8920", ["http://192.168.1.10:8920"]),
            // Browser paste of the web UI.
            ("http://192.168.1.10:8096/web/#/home", ["http://192.168.1.10:8096"]),
            ("http://192.168.1.10:8096/web/index.html#!/home.html", ["http://192.168.1.10:8096"]),
            ("http://nas.local/web/", ["http://nas.local:8096", "http://nas.local"]),
            // Trailing slashes, whitespace, uppercase scheme and host.
            ("http://192.168.1.10:8096///", ["http://192.168.1.10:8096"]),
            ("  192.168.1.10 :8096 \n", ["http://192.168.1.10:8096"]),
            ("HTTP://NAS.Local:8096", ["http://nas.local:8096"]),
            // https without a port stays on 443 (reverse proxy), no guessing.
            ("https://jellyfin.example.com", ["https://jellyfin.example.com"]),
            ("HTTPS://Jellyfin.Example.com/web/#/home", ["https://jellyfin.example.com"]),
            // A reverse-proxy base path is kept, and then no port is invented.
            ("https://example.com/jellyfin/", ["https://example.com/jellyfin"]),
            ("http://example.com/emby/web/index.html", ["http://example.com/emby"]),
            // Query and fragment never reach the API base.
            ("http://10.0.0.5:8096/?foo=bar#x", ["http://10.0.0.5:8096"]),
            // IPv6 literals.
            ("http://[fd00::10]:8096", ["http://[fd00::10]:8096"]),
            ("fd00::10", ["http://[fd00::10]:8096", "http://[fd00::10]"]),
            // Nothing typed.
            ("", []),
            ("   ", []),
        ]
        for row in table {
            XCTAssertEqual(ServerURLNormalizer.candidates(row.typed), row.expected, "typed: \(row.typed.debugDescription)")
        }
    }

    func testNormalizeReturnsTheFirstCandidate() {
        XCTAssertEqual(ServerURLNormalizer.normalize("192.168.1.10"), "http://192.168.1.10:8096")
        XCTAssertEqual(ServerURLNormalizer.normalize(""), "")
    }

    func testEveryCandidateIsAValidURL() {
        for typed in ["192.168.1.10", "nas.local/web/#/home", "fd00::10", "https://x.example/jellyfin"] {
            for candidate in ServerURLNormalizer.candidates(typed) {
                XCTAssertNotNil(URL(string: candidate + "/Users/AuthenticateByName"), candidate)
            }
        }
    }

    func testSignInMarkupSniffing() {
        XCTAssertTrue(SignInRequest.looksLikeMarkup(Data("\n  <!DOCTYPE html>".utf8)))
        XCTAssertFalse(SignInRequest.looksLikeMarkup(Data(" {\"AccessToken\":\"x\"}".utf8)))
        XCTAssertFalse(SignInRequest.looksLikeMarkup(Data()))
        XCTAssertLessThanOrEqual(SignInRequest.timeout, 15, "a dead LAN address must fail in 15 s or less")
    }
}

// MARK: - Candidate fallback

@MainActor
final class ServerCandidateFallbackTests: XCTestCase {
    func testRefusedPrimaryFallsBackToPortless() async throws {
        var tried: [String] = []
        let result = try await AppState.tryServerCandidates(["a", "b"]) { url -> String in
            tried.append(url)
            if url == "a" { throw URLError(.cannotConnectToHost) }
            return "ok"
        }
        XCTAssertEqual(tried, ["a", "b"])
        XCTAssertEqual(result.url, "b", "the URL that worked is the one saved")
    }

    func testTimeoutDoesNotTryTheNextCandidate() async {
        var tried: [String] = []
        do {
            _ = try await AppState.tryServerCandidates(["a", "b"]) { url -> String in
                tried.append(url)
                throw URLError(.timedOut)
            }
            XCTFail("should throw")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(tried, ["a"], "a dead address must fail once, not twice")
    }

    func testWrongPasswordOnTheFallbackIsTheErrorShown() async {
        do {
            _ = try await AppState.tryServerCandidates(["a", "b"]) { url -> String in
                if url == "a" { throw URLError(.cannotConnectToHost) }
                throw PlexAPIService.APIError.unauthorized
            }
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? PlexAPIService.APIError, .unauthorized)
        }
    }

    func testBothRefusedReportsThePrimary() async {
        do {
            _ = try await AppState.tryServerCandidates(["a", "b"]) { url -> String in
                if url == "a" { throw URLError(.cannotConnectToHost) }
                throw PlexAPIService.APIError.httpFailure(statusCode: 404)
            }
            XCTFail("should throw")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
    }
}

// MARK: - Typed URL shape (computed on device, only categories leave)

final class TypedServerURLShapeTests: XCTestCase {

    func testHostKindTable() {
        let table: [(String, AnalyticsHostKind)] = [
            ("10.1.2.3", .privateIPv4),
            ("172.16.0.1", .privateIPv4),
            ("172.31.255.1", .privateIPv4),
            ("172.32.0.1", .publicIPv4),
            ("192.168.1.10", .privateIPv4),
            ("100.64.0.1", .cgnat),
            ("100.127.255.1", .cgnat),
            ("100.128.0.1", .publicIPv4),
            ("169.254.10.1", .linkLocal),
            ("127.0.0.1", .loopback),
            ("localhost", .loopback),
            ("8.8.8.8", .publicIPv4),
            ("nas.local", .localMDNS),
            ("[fd00::10]", .ipv6),
            ("192-168-1-50.abc123.plex.direct", .plexDirect),
            ("jellyfin.example.com", .hostname),
            ("nas", .hostname),
            ("999.1.1.1", .hostname),
            ("", .unknown),
        ]
        for (host, expected) in table {
            XCTAssertEqual(TypedServerURLShape.hostKind(host), expected, host)
        }
    }

    func testShapeOfWhatWasTyped() {
        XCTAssertEqual(TypedServerURLShape(typed: "192.168.1.10"),
                       TypedServerURLShape(scheme: .noneTyped, hostKind: .privateIPv4, portTyped: false, pathTyped: false))
        XCTAssertEqual(TypedServerURLShape(typed: "HTTP://192.168.1.10:8096/web/#/home"),
                       TypedServerURLShape(scheme: .http, hostKind: .privateIPv4, portTyped: true, pathTyped: true))
        XCTAssertEqual(TypedServerURLShape(typed: "https://jf.example.com/"),
                       TypedServerURLShape(scheme: .https, hostKind: .hostname, portTyped: false, pathTyped: false))
        XCTAssertEqual(TypedServerURLShape(typed: "http://100.101.102.103:8096").hostKind, .cgnat)
    }
}

// MARK: - Buckets and the consecutive-failure ledger

final class ConnectBucketsAndLedgerTests: XCTestCase {
    func testCountBuckets() {
        XCTAssertEqual([0, 1, 2, 3, 4, 5, 9, 10, 250].map(AnalyticsBuckets.count),
                       ["0", "1", "2", "3", "4", "5_9", "5_9", "10_plus", "10_plus"])
    }

    func testElapsedBuckets() {
        XCTAssertEqual([0, 1.9, 2, 9.9, 10, 29, 30, 60, 60.1, 600].map(AnalyticsBuckets.elapsed),
                       ["lt_2s", "lt_2s", "2_10s", "2_10s", "10_30s", "10_30s", "30_60s", "30_60s", "gt_60s", "gt_60s"])
    }

    func testLedgerCountsRunsAndResetsOnSuccess() {
        var ledger = ConnectAttemptLedger()
        XCTAssertEqual(ledger.recordFailure(.connectionRefused), 1)
        XCTAssertEqual(ledger.recordFailure(.timeout), 2)
        let first = ledger.recordSuccess()
        XCTAssertEqual(first.priorFailures, 2)
        XCTAssertEqual(first.firstFailureReason, .connectionRefused)
        let clean = ledger.recordSuccess()
        XCTAssertEqual(clean.priorFailures, 0)
        XCTAssertNil(clean.firstFailureReason)
        XCTAssertEqual(ledger.recordFailure(.offline), 1, "a new run starts at 1")
    }

    @MainActor
    func testLedgerIsNotPersistedAcrossLaunches() {
        let first = AppState(credentialStore: ConnectTestStore())
        first.beginConnectAttempt(backend: .emby, method: .password)
        first.resolveConnectAttempt(.failed(.timeout, errorCode: nil))
        XCTAssertEqual(first.connectLedger.consecutiveFailures, 1)
        let relaunched = AppState(credentialStore: ConnectTestStore())
        XCTAssertEqual(relaunched.connectLedger.consecutiveFailures, 0)
    }
}

// MARK: - Wire contract and privacy guard

final class ConnectEventWireTests: XCTestCase {

    func testConnectFailedCarriesEveryDiagnosticKey() {
        let event = AnalyticsEvent.connectFailed(backend: .jellyfin, reason: .connectionRefused, context: AnalyticsConnectFailureContext(
            method: .password, attempt: 3, elapsedSeconds: 0.4, errorCode: -1004,
            urlShape: TypedServerURLShape(typed: "192.168.1.10")
        ))
        XCTAssertEqual(event.name, "connect.failed")
        XCTAssertEqual(event.parameters, [
            "backend": "jellyfin",
            "reason": "connection_refused",
            "method": "password",
            "attempt": "3",
            "elapsedBucket": "lt_2s",
            "errorCode": "-1004",
            "urlScheme": "none_typed",
            "hostKind": "private_ipv4",
            "portTyped": "false",
            "pathTyped": "false",
        ])
        XCTAssertNil(event.floatValue)
    }

    func testPlexFailureOmitsURLShapeAndMissingErrorCode() {
        let event = AnalyticsEvent.connectFailed(backend: .plex, reason: .plexNoReachableShared, context: AnalyticsConnectFailureContext(
            method: .pin, attempt: 12, elapsedSeconds: 45, errorCode: nil, urlShape: nil
        ))
        XCTAssertEqual(event.parameters, [
            "backend": "plex", "reason": "plex_no_reachable_shared", "method": "pin",
            "attempt": "10_plus", "elapsedBucket": "30_60s",
        ])
    }

    func testConnectCompletedCarriesPriorFailures() {
        let clean = AnalyticsEvent.connectCompleted(backend: .emby, serverCount: 1, priorFailures: 0, firstFailureReason: nil)
        XCTAssertEqual(clean.parameters, ["backend": "emby", "serverCount": "1", "priorFailures": "0"])

        let recovered = AnalyticsEvent.connectCompleted(backend: .jellyfin, serverCount: 1, priorFailures: 6, firstFailureReason: .httpNotFound)
        XCTAssertEqual(recovered.parameters, [
            "backend": "jellyfin", "serverCount": "1", "priorFailures": "5_9", "firstFailureReason": "http_not_found",
        ])
    }

    /// No connect parameter may ever carry a host, IP, port, path or account. The typed
    /// URLs below are full of them; none of it may reach a value.
    func testPrivacyGuardNoHostLikeValueEverLeaves() {
        let typedURLs = [
            "http://192.168.1.10:8096/web/#/home",
            "https://user:secret@jellyfin.example.com:8920/jellyfin",
            "100.101.102.103",
            "fd00::10",
            "http://[fe80::1]:8096",
            "nas.local",
            "192-168-1-50.abc123.plex.direct:32400",
            "HTTPS://MEDIA.EXAMPLE.ORG",
        ]
        let errors: [Error] = [
            URLError(.cannotConnectToHost), URLError(.timedOut), URLError(.serverCertificateUntrusted),
            URLError(.appTransportSecurityRequiresSecureConnection), URLError(.cannotFindHost),
            PlexAPIService.APIError.httpFailure(statusCode: 404), PlexAPIService.APIError.httpFailure(statusCode: 503),
            PlexAPIService.APIError.receivedMarkupInsteadOfJSON(statusCode: 200), PlexAPIService.APIError.unauthorized,
            NSError(domain: "jellyfin.example.com", code: 42, userInfo: [NSLocalizedDescriptionKey: "host 192.168.1.10 said no"]),
        ]
        var events: [AnalyticsEvent] = []
        for typed in typedURLs {
            for error in errors {
                for stage in [ConnectFailureStage.signIn, .quickConnectStart, .plexDiscovery, .plexPIN] {
                    let f = ConnectFailureClassifier.classify(error, backendName: "Jellyfin", stage: stage)
                    for attempt in [1, 7, 40] {
                        events.append(.connectFailed(backend: .jellyfin, reason: f.reason, context: AnalyticsConnectFailureContext(
                            method: .quickConnect, attempt: attempt, elapsedSeconds: Double(attempt) * 1.7,
                            errorCode: f.errorCode, urlShape: TypedServerURLShape(typed: typed)
                        )))
                    }
                }
            }
        }
        for reason in AnalyticsConnectFailureReason.allCases {
            events.append(.connectCompleted(backend: .plex, serverCount: 2, priorFailures: 3, firstFailureReason: reason))
        }

        let forbiddenFragments = ["192", "168", "example", "jellyfin", "secret", "user", "nas", "plex.direct", "fd00", "fe80", "8096", "8920", "32400", "said"]
        for event in events {
            for (key, value) in event.parameters {
                for ch in [".", ":", "/", "@", " "] {
                    XCTAssertFalse(value.contains(ch), "\(event.name).\(key) = \(value) contains '\(ch)'")
                }
                XCTAssertNotNil(value.range(of: "^-?[a-z0-9_]+$", options: .regularExpression),
                                "\(event.name).\(key) = \(value) is not fixed vocabulary or a number")
                // Backend names are allowed as the backend value only.
                guard key != "backend" else { continue }
                for fragment in forbiddenFragments where key != "errorCode" {
                    XCTAssertFalse(value.lowercased().contains(fragment), "\(event.name).\(key) = \(value) leaks '\(fragment)'")
                }
            }
        }
    }
}

// MARK: - Every connect.started resolves to exactly one terminal signal

final class ConnectTestStore: Nostalgex.CredentialStoring, @unchecked Sendable {
    var values: [String: String] = [:]
    @discardableResult func save(key: String, value: String) -> Bool { values[key] = value; return true }
    func load(key: String) -> String? { values[key] }
    func delete(key: String) { values[key] = nil }
}

private final class ConnectSpyAnalytics: AnalyticsService, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [(name: String, params: [String: String])] = []
    var events: [(name: String, params: [String: String])] { lock.lock(); defer { lock.unlock() }; return _events }
    var names: [String] { events.map(\.name) }
    func configure() {}
    func track(_ event: AnalyticsEvent, contextParameters: [String: String]) {
        // Only the connect stream: other AppState instances alive in the test process
        // (library loads, launch signals) share the global transport.
        guard event.name.hasPrefix("connect.") else { return }
        lock.lock(); _events.append((event.name, event.parameters)); lock.unlock()
    }
}

@MainActor
final class ConnectAttemptLifecycleTests: XCTestCase {
    private var spy: ConnectSpyAnalytics!

    override func setUp() async throws {
        spy = ConnectSpyAnalytics()
        Analytics.configure(with: spy)
    }

    override func tearDown() async throws {
        Analytics.configure(with: NoOpAnalytics())
    }

    private static let terminals: Set<String> = ["connect.completed", "connect.failed", "connect.cancelled", "connect.code_expired"]

    /// Walks the recorded stream and checks every started is followed by exactly one
    /// terminal before the next started.
    private func assertEveryStartResolvesOnce(file: StaticString = #filePath, line: UInt = #line) {
        var open = false
        for name in spy.names {
            if name == "connect.started" {
                XCTAssertFalse(open, "a connect.started was never resolved: \(spy.names)", file: file, line: line)
                open = true
            } else if Self.terminals.contains(name) {
                XCTAssertTrue(open, "terminal \(name) without a start: \(spy.names)", file: file, line: line)
                open = false
            }
        }
        XCTAssertFalse(open, "last connect.started never resolved: \(spy.names)", file: file, line: line)
    }

    func testEachOutcomeIsTheOnlyTerminal() {
        let outcomes: [(AppState.ConnectAttemptOutcome, String)] = [
            (.completed(serverCount: 1), "connect.completed"),
            (.failed(.timeout, errorCode: -1001), "connect.failed"),
            (.cancelled, "connect.cancelled"),
            (.codeExpired, "connect.code_expired"),
        ]
        for (outcome, expected) in outcomes {
            let state = AppState(credentialStore: ConnectTestStore())
            let before = spy.names.count
            state.beginConnectAttempt(backend: .jellyfin, method: .quickConnect)
            state.resolveConnectAttempt(outcome)
            // Late or duplicate resolutions are ignored.
            state.resolveConnectAttempt(.failed(.other, errorCode: nil))
            state.resolveConnectAttempt(.completed(serverCount: 1))
            state.cancelPINAuth()
            XCTAssertEqual(Array(spy.names[before...]), ["connect.started", expected])
        }
        assertEveryStartResolvesOnce()
    }

    func testSecondPressClosesTheFirstAttemptAsCancelled() {
        let state = AppState(credentialStore: ConnectTestStore())
        state.beginConnectAttempt(backend: .jellyfin, method: .password)
        state.beginConnectAttempt(backend: .jellyfin, method: .quickConnect)
        state.resolveConnectAttempt(.failed(.quickConnectDisabled, errorCode: 401))
        XCTAssertEqual(spy.names, ["connect.started", "connect.cancelled", "connect.started", "connect.failed"])
        XCTAssertEqual(spy.events[1].params["method"], "password", "the cancel names the superseded attempt")
        assertEveryStartResolvesOnce()
    }

    func testFailureCarriesAttemptElapsedAndShapeThenCompletedCarriesHistory() {
        let state = AppState(credentialStore: ConnectTestStore())
        let t0 = Date(timeIntervalSince1970: 1_000)
        state.beginConnectAttempt(backend: .emby, method: .password, typedURL: "192.168.1.20", now: t0)
        state.resolveConnectAttempt(.failed(.connectionRefused, errorCode: -1004), now: t0.addingTimeInterval(12))
        state.beginConnectAttempt(backend: .emby, method: .password, typedURL: "http://192.168.1.20:8096", now: t0)
        state.resolveConnectAttempt(.failed(.authInvalidCredentials, errorCode: nil), now: t0.addingTimeInterval(1))
        state.beginConnectAttempt(backend: .emby, method: .password, typedURL: "http://192.168.1.20:8096", now: t0)
        state.resolveConnectAttempt(.completed(serverCount: 1), now: t0.addingTimeInterval(1))

        let failures = spy.events.filter { $0.name == "connect.failed" }
        XCTAssertEqual(failures[0].params["attempt"], "1")
        XCTAssertEqual(failures[0].params["elapsedBucket"], "10_30s")
        XCTAssertEqual(failures[0].params["portTyped"], "false")
        XCTAssertEqual(failures[0].params["urlScheme"], "none_typed")
        XCTAssertEqual(failures[1].params["attempt"], "2")
        XCTAssertEqual(failures[1].params["portTyped"], "true")
        XCTAssertNil(failures[1].params["errorCode"])

        let completed = spy.events.last!
        XCTAssertEqual(completed.name, "connect.completed")
        XCTAssertEqual(completed.params["priorFailures"], "2")
        XCTAssertEqual(completed.params["firstFailureReason"], "connection_refused")
        assertEveryStartResolvesOnce()
    }

    func testCancelWithNothingInFlightSendsNothing() {
        let state = AppState(credentialStore: ConnectTestStore())
        state.cancelPINAuth()
        XCTAssertTrue(spy.names.isEmpty)
    }

    // End to end through the real sign-in entry points: nothing listens on port 1, so
    // the loopback connection is refused immediately.

    private func waitForAuthToFinish(_ state: AppState) async {
        var waited = 0
        while state.isAuthInProgress, waited < 200 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
    }

    func testJellyfinSignInToADeadPortResolvesAsConnectionRefused() async {
        let state = AppState(credentialStore: ConnectTestStore())
        state.authenticateJellyfin(serverURL: "http://127.0.0.1:1", username: "u", password: "p")
        await waitForAuthToFinish(state)
        XCTAssertFalse(state.isAuthInProgress)
        XCTAssertEqual(spy.names, ["connect.started", "connect.failed"])
        let failed = spy.events[1].params
        XCTAssertEqual(failed["reason"], "connection_refused")
        XCTAssertEqual(failed["hostKind"], "loopback")
        XCTAssertEqual(failed["portTyped"], "true")
        XCTAssertEqual(failed["method"], "password")
        XCTAssertEqual(state.authError, AppState.serverUnreachableMessage(URLError(.cannotConnectToHost), backend: "Jellyfin"))
        assertEveryStartResolvesOnce()
    }

    func testEmbySignInToADeadPortResolvesOnce() async {
        let state = AppState(credentialStore: ConnectTestStore())
        state.authenticateEmby(serverURL: "127.0.0.1:1", username: "u", password: "p")
        await waitForAuthToFinish(state)
        XCTAssertEqual(spy.names, ["connect.started", "connect.failed"])
        XCTAssertEqual(spy.events[1].params["backend"], "emby")
        XCTAssertEqual(spy.events[1].params["reason"], "connection_refused")
        assertEveryStartResolvesOnce()
    }

    func testQuickConnectToADeadPortIsUnreachableNotDisabled() async {
        let state = AppState(credentialStore: ConnectTestStore())
        state.startJellyfinQuickConnect(serverURL: "http://127.0.0.1:1")
        await waitForAuthToFinish(state)
        XCTAssertEqual(spy.names, ["connect.started", "connect.failed"])
        XCTAssertEqual(spy.events[1].params["reason"], "quick_connect_unreachable")
        XCTAssertFalse(state.authError?.contains("enabled") ?? true, state.authError ?? "")
        assertEveryStartResolvesOnce()
    }

    func testCancellingAnInFlightSignInResolvesAsCancelledOnly() async {
        let state = AppState(credentialStore: ConnectTestStore())
        // Unroutable TEST-NET address: the request hangs until cancelled.
        state.authenticateJellyfin(serverURL: "http://192.0.2.1:8096", username: "u", password: "p")
        state.cancelPINAuth()
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(spy.names, ["connect.started", "connect.cancelled"])
        XCTAssertNil(state.authError)
        assertEveryStartResolvesOnce()
    }
}
