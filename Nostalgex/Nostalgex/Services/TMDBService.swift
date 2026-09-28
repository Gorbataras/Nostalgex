import Foundation

struct TMDBService {
    let apiKey: String

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private static let baseURL = "https://api.themoviedb.org/3"

    // MARK: - Public API

    func fetchEnrichment(tmdbID: String, imdbID: String?, mediaType: String) async throws -> MediaEnrichment {
        let path = mediaType == "tv" ? "/tv/\(tmdbID)" : "/movie/\(tmdbID)"
        let url = "\(Self.baseURL)\(path)?api_key=\(apiKey)&append_to_response=keywords"

        guard let requestURL = URL(string: url) else {
            throw TMDBError.invalidURL
        }

        let (data, response) = try await Self.session.data(for: URLRequest(url: requestURL))

        guard let http = response as? HTTPURLResponse else {
            throw TMDBError.invalidResponse
        }

        if http.statusCode == 429 {
            throw TMDBError.rateLimited
        }

        guard http.statusCode == 200 else {
            throw TMDBError.httpError(http.statusCode)
        }

        return try parseResponse(data: data, tmdbID: tmdbID, imdbID: imdbID, mediaType: mediaType)
    }

    // MARK: - Response parsing

    private func parseResponse(data: Data, tmdbID: String, imdbID: String?, mediaType: String) throws -> MediaEnrichment {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        let keywords = extractKeywords(from: json, mediaType: mediaType)
        let networks = extractNetworks(from: json)
        let productionCompanies = extractProductionCompanies(from: json)
        let genres = extractGenres(from: json)

        return MediaEnrichment(
            tmdbID: tmdbID,
            imdbID: imdbID,
            mediaType: mediaType,
            keywords: keywords,
            networks: networks,
            productionCompanies: productionCompanies,
            tmdbGenres: genres,
            imdbRating: nil,
            imdbVotes: nil,
            rottenTomatoesScore: nil,
            metacriticScore: nil,
            awards: nil,
            fetchedAt: Date()
        )
    }

    private func extractKeywords(from json: [String: Any], mediaType: String) -> [String] {
        guard let keywordsObj = json["keywords"] as? [String: Any] else { return [] }
        // Movies: keywords.keywords[].name
        // TV: keywords.results[].name
        let key = mediaType == "tv" ? "results" : "keywords"
        guard let list = keywordsObj[key] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["name"] as? String }
    }

    private func extractNetworks(from json: [String: Any]) -> [String] {
        guard let list = json["networks"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["name"] as? String }
    }

    private func extractProductionCompanies(from json: [String: Any]) -> [String] {
        guard let list = json["production_companies"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["name"] as? String }
    }

    private func extractGenres(from json: [String: Any]) -> [String] {
        guard let list = json["genres"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["name"] as? String }
    }

    // MARK: - Errors

    enum TMDBError: Error {
        case invalidURL
        case invalidResponse
        case rateLimited
        case httpError(Int)
    }
}
