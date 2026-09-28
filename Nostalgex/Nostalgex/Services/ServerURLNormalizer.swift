import Foundation

/// Turns whatever someone typed into the Jellyfin / Emby "Server URL" field into the
/// base URL the API calls are appended to.
///
/// The failures this exists for, all seen in connect analytics:
/// - `192.168.1.10` with no port went to port 80, not Jellyfin's 8096.
/// - A URL copied from the browser (`http://host:8096/web/#/home`) had
///   `/Users/AuthenticateByName` glued onto the web UI path.
/// - Stray spaces and an uppercase scheme from the tvOS keyboard.
///
/// A reverse-proxy base path (`https://host/jellyfin`) is kept, and a port is never
/// added when one was typed or when the address is https.
enum ServerURLNormalizer {
    /// Jellyfin and Emby both listen here out of the box.
    static let defaultHTTPPort = 8096

    struct Parts: Equatable {
        /// Lowercased scheme, or nil when none was typed.
        var scheme: String?
        var userInfo: String?
        /// Lowercased. IPv6 literals keep their brackets.
        var host: String
        var port: Int?
        /// Everything after host[:port], as typed.
        var pathQueryFragment: String
    }

    /// Splits a typed address without validating it. Whitespace anywhere is dropped:
    /// no server base URL legitimately contains a space.
    static func split(_ raw: String) -> Parts {
        var s = String(raw.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        var scheme: String?
        if let range = s.range(of: "://") {
            let candidate = String(s[s.startIndex..<range.lowerBound])
            if !candidate.isEmpty, candidate.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) {
                scheme = candidate.lowercased()
                s = String(s[range.upperBound...])
            }
        }
        let authorityEnd = s.firstIndex(where: { "/?#".contains($0) }) ?? s.endIndex
        var authority = String(s[s.startIndex..<authorityEnd])
        let rest = String(s[authorityEnd...])

        var userInfo: String?
        if let at = authority.lastIndex(of: "@") {
            userInfo = String(authority[authority.startIndex..<at])
            authority = String(authority[authority.index(after: at)...])
        }

        var host = authority
        var port: Int?
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            host = String(authority[...close])
            let after = authority[authority.index(after: close)...]
            if after.hasPrefix(":"), let p = Int(after.dropFirst()) { port = p }
        } else if let colon = authority.lastIndex(of: ":"),
                  authority.firstIndex(of: ":") == colon {
            let portText = authority[authority.index(after: colon)...]
            host = String(authority[authority.startIndex..<colon])
            port = portText.isEmpty ? nil : Int(portText)
        } else if authority.contains(":") {
            // Bare IPv6 literal: bracket it so a port can follow.
            host = "[\(authority)]"
        }
        return Parts(scheme: scheme, userInfo: userInfo, host: host.lowercased(), port: port, pathQueryFragment: rest)
    }

    /// Base URLs to try, best guess first. Usually one. When no port was typed on a
    /// plain http address, `:8096` comes first and the portless form second, for the
    /// rare server that sits behind a reverse proxy on port 80.
    static func candidates(_ raw: String) -> [String] {
        let parts = split(raw)
        guard !parts.host.isEmpty else { return [] }
        let scheme = parts.scheme ?? "http"
        let path = basePath(parts.pathQueryFragment)

        func build(port: Int?) -> String {
            var out = "\(scheme)://"
            if let userInfo = parts.userInfo, !userInfo.isEmpty { out += "\(userInfo)@" }
            out += parts.host
            if let port { out += ":\(port)" }
            return out + path
        }

        if parts.port == nil, scheme == "http", path.isEmpty {
            return [build(port: defaultHTTPPort), build(port: nil)]
        }
        return [build(port: parts.port)]
    }

    /// The single best base URL (first candidate), or "" when nothing usable was typed.
    static func normalize(_ raw: String) -> String {
        candidates(raw).first ?? ""
    }

    /// Drops query, fragment, any `/web` UI path and trailing slashes. Keeps a proxy
    /// base path such as `/jellyfin`.
    static func basePath(_ pathQueryFragment: String) -> String {
        var path = pathQueryFragment
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(path[path.startIndex..<cut])
        }
        var components = path.split(separator: "/").map(String.init)
        if let web = components.firstIndex(where: { $0.lowercased() == "web" }) {
            components.removeSubrange(web...)
        }
        return components.isEmpty ? "" : "/" + components.joined(separator: "/")
    }
}

/// Shared rules for the Jellyfin / Emby sign-in requests (not library loads).
enum SignInRequest {
    /// Library calls keep the 60 s session default. A sign-in to a dead LAN address
    /// should fail in seconds, not a minute, or people press Sign In again and again.
    static let timeout: TimeInterval = 15

    /// First non-whitespace byte is `<`: an HTML login page from a proxy, or the web UI
    /// because the path was wrong. Reported as markup, not as a JSON decode error.
    static func looksLikeMarkup(_ data: Data) -> Bool {
        for byte in data {
            if byte == 9 || byte == 10 || byte == 13 || byte == 32 { continue }
            return byte == UInt8(ascii: "<")
        }
        return false
    }
}
