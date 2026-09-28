import Foundation

// Connect-failure diagnostics: one closed vocabulary, one classifier, and the coarse
// on-device categories that ride along with `connect.failed` / `connect.completed`.
//
// Privacy rule for everything in this file: only fixed vocabulary values or plain
// numbers leave the device. The typed URL, host, IP, username and raw error text never
// do. `TypedServerURLShape` is computed on device and only its categories are sent.

// MARK: - Failure reason

/// Why a sign-in failed. Closed on purpose: the dashboard groups by this, so a new
/// value must be a deliberate code change, never a free string built at runtime.
enum AnalyticsConnectFailureReason: String, Sendable, CaseIterable {
    // Server answered, but not with a session.
    case authInvalidCredentials = "auth_invalid_credentials"   // 401 / 403
    case httpNotFound = "http_not_found"                       // 404: usually a wrong path
    case httpClientError = "http_client_error"                 // other 4xx
    case httpServerError = "http_server_error"                 // 5xx
    case rateLimited = "rate_limited"                          // 429
    case markupResponse = "markup_response"                    // HTML/XML: proxy or web UI
    case invalidResponse = "invalid_response"                  // unexpected / undecodable

    // Transport (URLError).
    case dnsNotFound = "dns_not_found"
    case connectionRefused = "connection_refused"
    case timeout = "timeout"
    case offline = "offline"
    case atsBlockedHTTP = "ats_blocked_http"
    case tlsUntrustedCert = "tls_untrusted_cert"
    case tlsFailed = "tls_failed"
    case urlInvalid = "url_invalid"

    // Plex account flow.
    case plexNoServerOnAccount = "plex_no_server_on_account"
    case plexNoReachableOwned = "plex_no_reachable_owned"
    case plexNoReachableShared = "plex_no_reachable_shared"
    case plexDiscoveryFailed = "plex_discovery_failed"

    // Jellyfin Quick Connect.
    case quickConnectDisabled = "quick_connect_disabled"
    case quickConnectUnreachable = "quick_connect_unreachable"

    case other = "other"

    var wireValue: String { rawValue }

    /// Transport-level: nothing usable answered at the address.
    var isTransport: Bool {
        switch self {
        case .dnsNotFound, .connectionRefused, .timeout, .offline,
             .atsBlockedHTTP, .tlsUntrustedCert, .tlsFailed, .urlInvalid:
            return true
        default:
            return false
        }
    }
}

/// Which step of a sign-in failed. Only used to refine the reason; never sent.
enum ConnectFailureStage: Sendable {
    /// Username/password (Jellyfin, Emby) or the final Quick Connect exchange.
    case signIn
    /// Requesting a Jellyfin Quick Connect code.
    case quickConnectStart
    /// Asking plex.tv for the server list after the PIN was approved.
    case plexDiscovery
    /// Requesting a PIN from plex.tv.
    case plexPIN
}

/// The single classification both the UI message and the analytics reason come from.
struct ConnectFailure: Equatable, Sendable {
    let reason: AnalyticsConnectFailureReason
    /// Numeric only: a `URLError.Code` raw value or an HTTP status. Never text.
    let errorCode: Int?
    let message: String
}

enum ConnectFailureClassifier {

    /// Maps any error from a sign-in call to one reason, one numeric code, and the
    /// message the user sees. `backendName` is display text for the message only.
    static func classify(_ error: Error, backendName: String, stage: ConnectFailureStage = .signIn) -> ConnectFailure {
        let (base, code) = baseReason(for: error)
        let reason: AnalyticsConnectFailureReason
        switch stage {
        case .signIn, .plexPIN:
            reason = base
        case .plexDiscovery:
            reason = .plexDiscoveryFailed
        case .quickConnectStart:
            if base.isTransport {
                reason = .quickConnectUnreachable
            } else if base == .authInvalidCredentials {
                // Jellyfin answers 401/403 to Initiate when Quick Connect is turned off.
                reason = .quickConnectDisabled
            } else {
                reason = base
            }
        }
        // Quick Connect "unreachable" still gets the precise transport message.
        let messageReason = reason == .quickConnectUnreachable ? base : reason
        return ConnectFailure(
            reason: reason,
            errorCode: code,
            message: message(for: messageReason, backendName: backendName, errorCode: code)
        )
    }

    /// Error → reason + optional numeric code, with no stage context.
    static func baseReason(for error: Error) -> (AnalyticsConnectFailureReason, Int?) {
        if let api = error as? PlexAPIService.APIError {
            switch api {
            case .unauthorized:
                return (.authInvalidCredentials, nil)
            case .invalidResponse:
                return (.invalidResponse, nil)
            case .noReachableServer:
                return (.plexNoReachableOwned, nil)
            case .receivedMarkupInsteadOfJSON(let status):
                return (.markupResponse, status)
            case .httpFailure(let status):
                switch status {
                case 401, 403: return (.authInvalidCredentials, status)
                case 404: return (.httpNotFound, status)
                case 429: return (.rateLimited, status)
                case 400...499: return (.httpClientError, status)
                case 500...599: return (.httpServerError, status)
                default: return (.invalidResponse, status)
                }
            }
        }
        if error is DecodingError { return (.invalidResponse, nil) }
        let urlError = error as? URLError
            ?? ((error as NSError).underlyingErrors.first as? URLError)
        guard let urlError else { return (.other, nil) }
        let code = urlError.code.rawValue
        switch urlError.code {
        case .appTransportSecurityRequiresSecureConnection:
            return (.atsBlockedHTTP, code)
        case .cannotFindHost, .dnsLookupFailed:
            return (.dnsNotFound, code)
        case .cannotConnectToHost:
            return (.connectionRefused, code)
        case .timedOut:
            return (.timeout, code)
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return (.offline, code)
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
            return (.tlsUntrustedCert, code)
        case .secureConnectionFailed:
            return (.tlsFailed, code)
        case .badURL, .unsupportedURL:
            return (.urlInvalid, code)
        case .badServerResponse, .cannotParseResponse, .cannotDecodeRawData, .cannotDecodeContentData, .zeroByteResource:
            return (.invalidResponse, code)
        default:
            return (.other, code)
        }
    }

    /// User-facing copy per reason. Short, plain, no em dashes. The Plex account
    /// reasons are worded at their call sites because they carry server counts.
    static func message(for reason: AnalyticsConnectFailureReason, backendName: String, errorCode: Int?) -> String {
        switch reason {
        case .authInvalidCredentials:
            return "Incorrect username or password."
        case .httpNotFound:
            return "That address answered, but it isn't the \(backendName) server. Remove anything after the port, like /web."
        case .markupResponse:
            return "That address sent back a web page, not \(backendName). Check the port, and remove anything after it."
        case .httpClientError:
            return "The \(backendName) server turned down the request\(errorCode.map { " (HTTP \($0))" } ?? ""). Check the address."
        case .httpServerError:
            return "The \(backendName) server hit an error\(errorCode.map { " (HTTP \($0))" } ?? ""). Try again in a moment."
        case .rateLimited:
            return "Too many tries in a row. Wait a minute, then try again."
        case .invalidResponse:
            return "That address answered, but not like a \(backendName) server. Check the URL and port."
        case .atsBlockedHTTP:
            return "tvOS blocked the plain http:// address. Try the https:// address instead."
        case .dnsNotFound:
            return "Could not find that host. Check the address."
        case .connectionRefused:
            return "Nothing answered at that address and port. Check the port (Jellyfin and Emby default to 8096)."
        case .timeout:
            return "The \(backendName) server took too long to answer. Check the address, or that the Apple TV can reach it."
        case .offline:
            return "No network. Check the Apple TV's connection."
        case .tlsUntrustedCert, .tlsFailed:
            return "The server's HTTPS certificate is not trusted by the Apple TV\(errorCode.map { " (error \($0))" } ?? ""). Try its http:// LAN address."
        case .urlInvalid:
            return "That doesn't look like a server address. Check the URL."
        case .quickConnectDisabled:
            return "Quick Connect is off on this server. Turn it on in the \(backendName) dashboard, or sign in with your password."
        case .quickConnectUnreachable:
            return "Could not reach the \(backendName) server to start Quick Connect. Check the URL."
        case .plexNoServerOnAccount, .plexNoReachableOwned, .plexNoReachableShared:
            return "Signed in, but no Plex server was reachable. Make sure it's running, then try again."
        case .plexDiscoveryFailed:
            return "Signed in, but couldn't reach plex.tv to find your servers. Check your connection and try again."
        case .other:
            if let errorCode {
                return "Could not reach the \(backendName) server (error \(errorCode)). Check the URL."
            }
            return "Could not reach the \(backendName) server. Check the URL."
        }
    }
}

// MARK: - Buckets

/// Coarse buckets so the dashboard gets a small, fixed set of values.
enum AnalyticsBuckets {
    /// Consecutive-failure counts: `1|2|3|4|5_9|10_plus` (and `0` for priorFailures).
    static func count(_ n: Int) -> String {
        switch n {
        case ..<1: return "0"
        case 1...4: return String(n)
        case 5...9: return "5_9"
        default: return "10_plus"
        }
    }

    /// How long the attempt ran before failing: `lt_2s|2_10s|10_30s|30_60s|gt_60s`.
    static func elapsed(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<2: return "lt_2s"
        case ..<10: return "2_10s"
        case ..<30: return "10_30s"
        case ...60: return "30_60s"
        default: return "gt_60s"
        }
    }
}

// MARK: - Typed URL shape

/// What kind of address the user typed. The address itself never leaves the device.
enum AnalyticsHostKind: String, Sendable, CaseIterable {
    case privateIPv4 = "private_ipv4"
    case cgnat = "cgnat_100_64"
    case linkLocal = "link_local"
    case loopback = "loopback"
    case publicIPv4 = "public_ipv4"
    case ipv6 = "ipv6"
    case localMDNS = "local_mdns"
    case plexDirect = "plex_direct"
    case hostname = "hostname"
    case unknown = "unknown"
}

enum AnalyticsURLScheme: String, Sendable {
    case http
    case https
    case noneTyped = "none_typed"
    case other
}

/// Coarse, on-device categories of the URL the user typed (before normalization).
struct TypedServerURLShape: Equatable, Sendable {
    let scheme: AnalyticsURLScheme
    let hostKind: AnalyticsHostKind
    let portTyped: Bool
    let pathTyped: Bool

    init(scheme: AnalyticsURLScheme, hostKind: AnalyticsHostKind, portTyped: Bool, pathTyped: Bool) {
        self.scheme = scheme
        self.hostKind = hostKind
        self.portTyped = portTyped
        self.pathTyped = pathTyped
    }

    init(typed raw: String) {
        let parts = ServerURLNormalizer.split(raw)
        switch parts.scheme {
        case nil: scheme = .noneTyped
        case "http": scheme = .http
        case "https": scheme = .https
        default: scheme = .other
        }
        hostKind = Self.hostKind(parts.host)
        portTyped = parts.port != nil
        pathTyped = !parts.pathQueryFragment.isEmpty && parts.pathQueryFragment != "/"
    }

    var wireParameters: [String: String] {
        [
            "urlScheme": scheme.rawValue,
            "hostKind": hostKind.rawValue,
            "portTyped": portTyped ? "true" : "false",
            "pathTyped": pathTyped ? "true" : "false",
        ]
    }

    static func hostKind(_ rawHost: String) -> AnalyticsHostKind {
        let host = rawHost.lowercased()
        guard !host.isEmpty else { return .unknown }
        if host.hasPrefix("[") || host.contains(":") { return .ipv6 }
        if host == "localhost" { return .loopback }
        if host.hasSuffix(".plex.direct") { return .plexDirect }
        if host.hasSuffix(".local") { return .localMDNS }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        let nums = octets.compactMap { UInt8($0) }
        if octets.count == 4, nums.count == 4 {
            let (a, b) = (nums[0], nums[1])
            if a == 10 || (a == 192 && b == 168) || (a == 172 && (16...31).contains(b)) { return .privateIPv4 }
            if a == 100 && (64...127).contains(b) { return .cgnat }
            if a == 169 && b == 254 { return .linkLocal }
            if a == 127 { return .loopback }
            return .publicIPv4
        }
        return .hostname
    }
}

// MARK: - Failure context

/// Everything besides `backend` and `reason` that rides on `connect.failed`.
struct AnalyticsConnectFailureContext: Equatable, Sendable {
    var method: AnalyticsConnectMethod
    /// This failure's position in the current run of consecutive failures (1-based).
    var attempt: Int
    var elapsedSeconds: TimeInterval
    var errorCode: Int?
    /// Jellyfin / Emby only: categories of the URL the user typed.
    var urlShape: TypedServerURLShape?

    var wireParameters: [String: String] {
        var params: [String: String] = [
            "method": method.wireValue,
            "attempt": AnalyticsBuckets.count(max(attempt, 1)),
            "elapsedBucket": AnalyticsBuckets.elapsed(elapsedSeconds),
        ]
        if let errorCode { params["errorCode"] = String(errorCode) }
        if let urlShape {
            for (key, value) in urlShape.wireParameters { params[key] = value }
        }
        return params
    }
}

// MARK: - Consecutive-failure ledger

/// In-memory only: cleared on success and on app restart, never persisted. Lets
/// `connect.completed` say how many failures came first, so "how many failing users
/// eventually connected" is a dashboard filter.
struct ConnectAttemptLedger: Equatable, Sendable {
    private(set) var consecutiveFailures = 0
    private(set) var firstFailureReason: AnalyticsConnectFailureReason?

    /// Records a failure and returns its 1-based position in the current run.
    mutating func recordFailure(_ reason: AnalyticsConnectFailureReason) -> Int {
        if consecutiveFailures == 0 { firstFailureReason = reason }
        consecutiveFailures += 1
        return consecutiveFailures
    }

    /// Records a success, returns what came before it, and resets.
    mutating func recordSuccess() -> (priorFailures: Int, firstFailureReason: AnalyticsConnectFailureReason?) {
        let result = (consecutiveFailures, firstFailureReason)
        consecutiveFailures = 0
        firstFailureReason = nil
        return result
    }
}
