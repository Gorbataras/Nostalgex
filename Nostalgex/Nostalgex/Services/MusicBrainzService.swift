import Foundation

/// MusicBrainz recording search + lookup (free API, 1 req/sec).
/// https://musicbrainz.org/doc/MusicBrainz_API
actor MusicBrainzService {

    struct RecordingMatch: Sendable {
        let mbid: String
        let recordingTitle: String
        let artist: String?
        let genres: [String]
        let releaseYear: Int?
    }

    enum MusicBrainzError: Error {
        case invalidURL
        case httpError(Int)
        case decodeFailed
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private static let baseURL = "https://musicbrainz.org/ws/2"
    private static let userAgent = "Nostalgex/1.0.2 (https://www.nostalgex.app)"

    private var lastRequestAt: Date = .distantPast

    func resolveRecording(title: String, artist: String?, year: Int?) async throws -> RecordingMatch? {
        let song = MusicTitleParser.stripYearSuffix(title)
        guard !song.isEmpty else { return nil }

        guard let searchHit = try await searchBestRecording(songTitle: song, artist: artist, year: year) else {
            return nil
        }

        if let detailed = try await lookupRecording(mbid: searchHit.mbid) {
            return detailed
        }
        return RecordingMatch(
            mbid: searchHit.mbid,
            recordingTitle: searchHit.title,
            artist: searchHit.artist,
            genres: [],
            releaseYear: searchHit.year
        )
    }

    // MARK: - Search

    private struct SearchHit {
        let mbid: String
        let title: String
        let artist: String?
        let score: Int
        let year: Int?
    }

    private func searchBestRecording(songTitle: String, artist: String?, year: Int?) async throws -> SearchHit? {
        var parts = ["recording:\"\(escapeQuery(songTitle))\"", "video:true"]
        if let artist, !artist.isEmpty {
            parts.append("artist:\"\(escapeQuery(artist))\"")
        }
        let query = parts.joined(separator: " AND ")
        guard let url = URL(string: "\(Self.baseURL)/recording?query=\(encodedQuery(query))&fmt=json&limit=10") else {
            throw MusicBrainzError.invalidURL
        }

        let data = try await fetch(url: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recordings = json["recordings"] as? [[String: Any]],
              !recordings.isEmpty else { return nil }

        let songLower = songTitle.lowercased()
        var best: (hit: SearchHit, rank: Int)?

        for rec in recordings {
            guard let mbid = rec["id"] as? String,
                  let title = rec["title"] as? String else { continue }
            let score = rec["score"] as? Int ?? 0
            let artistName = primaryArtistName(from: rec)
            let recYear = firstReleaseYear(from: rec)

            var rank = score
            let titleLower = title.lowercased()
            if titleLower == songLower { rank += 40 }
            else if titleLower.contains(songLower) || songLower.contains(titleLower) { rank += 20 }

            if let artist, let artistName,
               artistName.lowercased().contains(artist.lowercased()) { rank += 25 }

            if let year, let recYear, year == recYear { rank += 15 }
            else if let year, let recYear, abs(year - recYear) <= 1 { rank += 8 }

            let hit = SearchHit(mbid: mbid, title: title, artist: artistName, score: score, year: recYear)
            if best == nil || rank > best!.rank { best = (hit, rank) }
        }

        return best?.hit
    }

    // MARK: - Lookup (tags + credits)

    private func lookupRecording(mbid: String) async throws -> RecordingMatch? {
        guard let url = URL(string: "\(Self.baseURL)/recording/\(mbid)?inc=artist-credits+tags+releases&fmt=json") else {
            throw MusicBrainzError.invalidURL
        }
        let data = try await fetch(url: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String else { return nil }

        let artist = primaryArtistName(from: json)
        let tags = extractTagNames(from: json)
        let genres = Self.mapTagsToChannelGenres(tags)
        let year = firstReleaseYear(from: json)

        return RecordingMatch(
            mbid: mbid,
            recordingTitle: title,
            artist: artist,
            genres: genres,
            releaseYear: year
        )
    }

    // MARK: - HTTP

    private func fetch(url: URL) async throws -> Data {
        let elapsed = Date().timeIntervalSince(lastRequestAt)
        if elapsed < 1.05 {
            try await Task.sleep(nanoseconds: UInt64((1.05 - elapsed) * 1_000_000_000))
        }
        lastRequestAt = Date()

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MusicBrainzError.decodeFailed }
        guard http.statusCode == 200 else { throw MusicBrainzError.httpError(http.statusCode) }
        return data
    }

    // MARK: - Parsing helpers

    private func primaryArtistName(from json: [String: Any]) -> String? {
        if let credits = json["artist-credit"] as? [[String: Any]] {
            for credit in credits {
                if let name = credit["name"] as? String, !name.isEmpty { return name }
                if let artist = credit["artist"] as? [String: Any],
                   let name = artist["name"] as? String, !name.isEmpty { return name }
            }
        }
        return nil
    }

    private func extractTagNames(from json: [String: Any]) -> [String] {
        guard let tagList = json["tags"] as? [[String: Any]] else { return [] }
        return tagList.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
    }

    private func firstReleaseYear(from json: [String: Any]) -> Int? {
        guard let releases = json["releases"] as? [[String: Any]] else { return nil }
        for release in releases {
            if let date = release["date"] as? String, date.count >= 4,
               let year = Int(date.prefix(4)) { return year }
        }
        return nil
    }

    private func escapeQuery(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "")
    }

    private func encodedQuery(_ query: String) -> String {
        query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
    }

    /// Map MusicBrainz tag vocabulary to genres used in channels.json.
    static func mapTagsToChannelGenres(_ tags: [String]) -> [String] {
        var out: [String] = []
        func add(_ g: String) {
            if !out.contains(where: { $0.caseInsensitiveCompare(g) == .orderedSame }) {
                out.append(g)
            }
        }

        for tag in tags {
            let t = tag.lowercased()
            if t.contains("pop") && !t.contains("k-pop") { add("Pop") }
            if t.contains("rock") {
                if t.contains("alternative") || t.contains("indie") { add("Alternative Rock"); add("Indie Rock") }
                else if t.contains("hard rock") || t.contains("hard-rock") { add("Hard Rock") }
                else if t.contains("classic rock") { add("Classic Rock") }
                else { add("Rock") }
            }
            if t.contains("country") { add("Country"); if t.contains("rock") { add("Country Rock") } }
            if t.contains("hip hop") || t.contains("hip-hop") { add("Hip-Hop"); add("Hip Hop") }
            if t == "rap" || t.contains("gangsta") { add("Rap") }
            if t.contains("r&b") || t.contains("rhythm and blues") || t == "soul" { add("R&B"); add("Soul") }
            if t.contains("acoustic") { add("Acoustic") }
            if t.contains("electronic") || t.contains("dance") || t.contains("edm") ||
               t.contains("house") || t.contains("techno") || t.contains("trance") { add("Dance") }
            if t.contains("metal") { add("Metal"); add("Hard Rock"); add("Rock") }
            if t.contains("punk") { add("Rock"); add("Alternative") }
            if t.contains("folk") { add("Acoustic") }
            if t.contains("latin") || t.contains("reggaeton") || t.contains("reggaetón") { add("Latin") }
            if t.contains("funk") { add("Funk") }
            if t.contains("disco") { add("Disco") }
        }
        return out
    }
}
