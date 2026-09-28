import Foundation

/// Raw OMDb fetch result — transient, gets merged into MediaEnrichment by the orchestrator.
struct OMDBResult {
    let imdbID: String
    let imdbRating: Double?
    let imdbVotes: Int?
    let rottenTomatoesScore: Int?
    let metacriticScore: Int?
    let awards: String?
}

/// OMDb API wrapper. Mirrors TMDBService shape.
struct OMDBService {
    let apiKey: String

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private static let baseURL = "https://www.omdbapi.com/"

    // MARK: - Public API

    func fetch(imdbID: String) async throws -> OMDBResult {
        guard !apiKey.isEmpty else { throw OMDBError.notConfigured }

        let url = "\(Self.baseURL)?i=\(imdbID)&apikey=\(apiKey)&tomatoes=true"
        guard let requestURL = URL(string: url) else {
            throw OMDBError.invalidURL
        }

        let (data, response) = try await Self.session.data(for: URLRequest(url: requestURL))

        guard let http = response as? HTTPURLResponse else {
            throw OMDBError.invalidResponse
        }

        guard http.statusCode == 200 else {
            throw OMDBError.httpError(http.statusCode)
        }

        return try parseResponse(data: data, imdbID: imdbID)
    }

    // MARK: - Response parsing

    private func parseResponse(data: Data, imdbID: String) throws -> OMDBResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OMDBError.invalidResponse
        }

        // OMDb signals errors via { "Response": "False", "Error": "..." }
        if let response = json["Response"] as? String, response == "False" {
            let err = (json["Error"] as? String) ?? ""
            if err.lowercased().contains("limit") || err.lowercased().contains("reached") {
                throw OMDBError.rateLimited
            }
            if err.lowercased().contains("not found") || err.lowercased().contains("incorrect imdb") {
                throw OMDBError.notFound
            }
            throw OMDBError.apiError(err)
        }

        let imdbRating = parseDouble(json["imdbRating"])
        let imdbVotes = parseVotes(json["imdbVotes"])
        let rt = extractRottenTomatoesScore(from: json)
        let metacritic = parseInt(json["Metascore"])
        let awards = (json["Awards"] as? String).flatMap { $0 == "N/A" ? nil : $0 }

        return OMDBResult(
            imdbID: imdbID,
            imdbRating: imdbRating,
            imdbVotes: imdbVotes,
            rottenTomatoesScore: rt,
            metacriticScore: metacritic,
            awards: awards
        )
    }

    private func parseDouble(_ any: Any?) -> Double? {
        guard let s = any as? String, s != "N/A" else { return nil }
        return Double(s)
    }

    private func parseInt(_ any: Any?) -> Int? {
        guard let s = any as? String, s != "N/A" else { return nil }
        return Int(s)
    }

    /// Parses strings like "1,234,567" → 1234567, or "N/A" → nil.
    private func parseVotes(_ any: Any?) -> Int? {
        guard let s = any as? String, s != "N/A" else { return nil }
        return Int(s.replacingOccurrences(of: ",", with: ""))
    }

    /// Finds the Rotten Tomatoes entry in the `Ratings` array and strips the `%`.
    private func extractRottenTomatoesScore(from json: [String: Any]) -> Int? {
        guard let ratings = json["Ratings"] as? [[String: Any]] else { return nil }
        for rating in ratings {
            if let source = rating["Source"] as? String, source == "Rotten Tomatoes",
               let value = rating["Value"] as? String {
                let trimmed = value.replacingOccurrences(of: "%", with: "")
                return Int(trimmed)
            }
        }
        return nil
    }

    // MARK: - Errors

    enum OMDBError: Error {
        case notConfigured
        case invalidURL
        case invalidResponse
        case rateLimited       // daily quota exhausted
        case notFound          // IMDb ID not in OMDb
        case httpError(Int)
        case apiError(String)
    }
}
