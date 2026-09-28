import Foundation

struct SupabaseService {
    let projectURL: String
    let anonKey: String

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private var restURL: String { "\(projectURL)/rest/v1" }

    private var headers: [String: String] {
        [
            "apikey": anonKey,
            "Authorization": "Bearer \(anonKey)",
            "Content-Type": "application/json",
        ]
    }

    // MARK: - Fetch enrichments by TMDB IDs

    /// `onProgress` reports (chunksDone, chunkTotal). The chunks run sequentially, so on a
    /// large library this loop is long enough that the loading screen needs to say so.
    func fetchEnrichments(
        tmdbIDs: [String],
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [MediaEnrichment] {
        guard !tmdbIDs.isEmpty else { return [] }

        // PostgREST supports batches via in filter
        // Split into chunks of 500 to avoid URL length limits
        var allResults: [MediaEnrichment] = []
        let chunks = tmdbIDs.chunked(into: 500)
        for (chunkIndex, chunk) in chunks.enumerated() {
            onProgress?(chunkIndex, chunks.count)
            let ids = chunk.joined(separator: ",")
            let urlString = "\(restURL)/media_enrichments?tmdb_id=in.(\(ids))&select=*"

            guard let url = URL(string: urlString) else { continue }
            var req = URLRequest(url: url)
            headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }

            let (data, response) = try await Self.session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                print("[Enrichment] Supabase fetch failed: HTTP \(code)")
                continue
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let str = try container.decode(String.self)
                if let date = ISO8601DateFormatter().date(from: str) { return date }
                // Supabase returns fractional seconds
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: str) { return date }
                return Date()
            }

            do {
                let results = try decoder.decode([MediaEnrichment].self, from: data)
                allResults.append(contentsOf: results)
            } catch {
                print("[Enrichment] Supabase DECODE FAILED: \(error)")
                if let raw = String(data: data, encoding: .utf8)?.prefix(500) {
                    print("[Enrichment] Raw response: \(raw)")
                }
            }
        }
        onProgress?(chunks.count, chunks.count)
        return allResults
    }

    // MARK: - Upsert enrichments

    func upsertEnrichments(_ enrichments: [MediaEnrichment]) async throws {
        guard !enrichments.isEmpty else { return }

        let urlString = "\(restURL)/media_enrichments"
        guard let url = URL(string: urlString) else { return }

        // Batch in chunks of 200
        for chunk in enrichments.chunked(into: 200) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            req.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            req.httpBody = try encoder.encode(chunk)

            let (_, response) = try await Self.session.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code >= 300 {
                print("[Enrichment] Supabase upsert failed: HTTP \(code)")
            }
        }
    }
}

// MARK: - Array chunking helper

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
