import Foundation
import Observation

/// Small actor-isolated flag so background tasks can coordinate OMDb rate-limit state
/// without touching MainActor-isolated EnrichmentService state.
private actor OMDBRateLimitFlag {
    var limited: Bool = false
    func mark() { limited = true }
    func isLimited() -> Bool { limited }
}

@Observable
@MainActor
class EnrichmentService {

    // In-memory cache: tmdbID -> MediaEnrichment (TMDB + optional OMDb merged)
    private(set) var cache: [String: MediaEnrichment] = [:]

    // Progress tracking
    var isEnriching: Bool = false
    var statusMessage: String = ""
    var progress: Double = 0 // 0.0 to 1.0
    var enrichedCount: Int = 0
    var totalToEnrich: Int = 0

    private let tmdb = TMDBService(apiKey: TMDBConfig.tmdbAPIKey)
    private let omdb = OMDBService(apiKey: TMDBConfig.omdbAPIKey)
    private let supabase = SupabaseService(
        projectURL: TMDBConfig.supabaseURL,
        anonKey: TMDBConfig.supabaseAnonKey
    )

    // MARK: - Public API

    /// Look up enrichment data for a media item
    func enrichment(for item: PlexMediaItem) -> MediaEnrichment? {
        guard let tmdbID = item.tmdbID else { return nil }
        return cache[tmdbID]
    }

    /// Enrich all items in the library. Runs in background, updates progress.
    func enrichItems(_ items: [PlexMediaItem]) async {
        guard !TMDBConfig.tmdbAPIKey.isEmpty,
              !TMDBConfig.supabaseURL.isEmpty else {
            print("[Enrichment] Skipping: API keys not configured")
            return
        }

        isEnriching = true
        statusMessage = "Preparing..."
        progress = 0

        // Step 1: Deduplicate TMDB IDs
        // TV episodes share a show-level TMDB ID, so group by ID
        // Track an IMDb ID per TMDB ID when available (first one wins)
        struct WorkItem { let tmdbID: String; let imdbID: String?; let mediaType: String }
        var workItemsByTMDB: [String: WorkItem] = [:]
        for item in items {
            guard let tmdbID = item.tmdbID else { continue }
            let mediaType = item.type == .episode ? "tv" : "movie"
            if let existing = workItemsByTMDB[tmdbID] {
                // Fill in missing IMDb ID if a later item has one
                if existing.imdbID == nil, let imdb = item.imdbID {
                    workItemsByTMDB[tmdbID] = WorkItem(tmdbID: tmdbID, imdbID: imdb, mediaType: existing.mediaType)
                }
            } else {
                workItemsByTMDB[tmdbID] = WorkItem(tmdbID: tmdbID, imdbID: item.imdbID, mediaType: mediaType)
            }
        }

        let total = workItemsByTMDB.count
        let omdbEnabled = !TMDBConfig.omdbAPIKey.isEmpty
        let withIMDB = workItemsByTMDB.values.filter { $0.imdbID != nil }.count
        print("[Enrichment] \(total) unique TMDB IDs from \(items.count) items, \(withIMDB) with IMDb IDs, OMDb \(omdbEnabled ? "enabled" : "disabled")")

        guard total > 0 else {
            statusMessage = "No TMDB IDs found"
            isEnriching = false
            return
        }

        // Step 2: Check Supabase cache
        statusMessage = "Checking metadata cache"
        let allIDs = Array(workItemsByTMDB.keys)
        var cached: [MediaEnrichment] = []
        do {
            cached = try await supabase.fetchEnrichments(tmdbIDs: allIDs) { done, total in
                guard total > 1 else { return }
                Task { @MainActor [weak self] in
                    self?.statusMessage = "Checking metadata cache \(done)/\(total)"
                }
            }
            for enrichment in cached {
                cache[enrichment.tmdbID] = enrichment
            }
            let withOMDBCached = cached.filter { $0.imdbRating != nil }.count
            print("[Enrichment] \(cached.count)/\(total) cached in Supabase (\(withOMDBCached) with OMDb)")
        } catch {
            print("[Enrichment] Supabase cache check failed: \(error)")
        }

        // Step 3: Identify what needs fetching
        // Three buckets:
        //   needsBoth: no TMDB cache row at all
        //   needsOMDBOnly: has TMDB cache row, has imdbID, but no imdbRating yet
        let cachedByID = Dictionary(cached.map { ($0.tmdbID, $0) }, uniquingKeysWith: { first, _ in first })

        var needsBoth: [WorkItem] = []
        var needsOMDBOnly: [(tmdbID: String, imdbID: String, existing: MediaEnrichment)] = []

        for (tmdbID, work) in workItemsByTMDB {
            if let existing = cachedByID[tmdbID] {
                if omdbEnabled, existing.imdbRating == nil, let imdbID = work.imdbID ?? existing.imdbID {
                    needsOMDBOnly.append((tmdbID, imdbID, existing))
                }
            } else {
                needsBoth.append(work)
            }
        }

        totalToEnrich = needsBoth.count + needsOMDBOnly.count
        enrichedCount = 0

        if totalToEnrich == 0 {
            print("[Enrichment] All items already fully cached")
            statusMessage = ""
            progress = 1
            isEnriching = false
            return
        }

        print("[Enrichment] Fetching \(needsBoth.count) new (TMDB+OMDb) + \(needsOMDBOnly.count) OMDb-only")
        statusMessage = "Fetching metadata 0/\(totalToEnrich)"

        var newEnrichments: [MediaEnrichment] = []
        let rateLimitFlag = OMDBRateLimitFlag()
        let tmdbService = tmdb
        let omdbService = omdb

        // Step 4a: Fetch brand new items (TMDB + OMDb in parallel per item)
        // Concurrency capped at 10 (OMDb is the slower/tighter-limited of the two)
        let maxConcurrency = 10
        let needsBothList = needsBoth

        await withTaskGroup(of: MediaEnrichment?.self) { group in
            var index = 0

            func launch(_ work: WorkItem, flag: OMDBRateLimitFlag) -> Void {
                group.addTask {
                    // Fetch TMDB first (required)
                    let tmdbResult: MediaEnrichment
                    do {
                        tmdbResult = try await tmdbService.fetchEnrichment(
                            tmdbID: work.tmdbID,
                            imdbID: work.imdbID,
                            mediaType: work.mediaType
                        )
                    } catch TMDBService.TMDBError.rateLimited {
                        print("[Enrichment] TMDB rate limited on \(work.tmdbID)")
                        return nil
                    } catch {
                        print("[Enrichment] TMDB failed \(work.tmdbID): \(error)")
                        return nil
                    }

                    // Fetch OMDb if available and enabled
                    guard omdbEnabled, let imdbID = work.imdbID else { return tmdbResult }
                    if await flag.isLimited() { return tmdbResult }
                    do {
                        let omdbResult = try await omdbService.fetch(imdbID: imdbID)
                        return tmdbResult.merging(omdb: omdbResult)
                    } catch OMDBService.OMDBError.rateLimited {
                        print("[Enrichment] OMDb rate limit hit, disabling OMDb for rest of session")
                        await flag.mark()
                        return tmdbResult
                    } catch OMDBService.OMDBError.notFound {
                        return tmdbResult
                    } catch OMDBService.OMDBError.httpError(let code) {
                        // 401/403 = bad key, 429 = rate-limited, 5xx = server down — disable for the session
                        if code == 401 || code == 403 || code == 429 || code >= 500 {
                            print("[Enrichment] OMDb disabled for session (HTTP \(code))")
                            await flag.mark()
                        }
                        return tmdbResult
                    } catch {
                        print("[Enrichment] OMDb failed \(imdbID): \(error)")
                        return tmdbResult
                    }
                }
            }

            // Seed initial batch
            while index < maxConcurrency && index < needsBothList.count {
                launch(needsBothList[index], flag: rateLimitFlag)
                index += 1
            }

            // Drain + refill (throttle UI updates to every 10 items to prevent SwiftUI lag)
            var pendingCount = 0
            for await result in group {
                if let enrichment = result {
                    newEnrichments.append(enrichment)
                    cache[enrichment.tmdbID] = enrichment
                }
                pendingCount += 1

                if pendingCount >= 5 || (enrichedCount + pendingCount) >= totalToEnrich {
                    enrichedCount += pendingCount
                    progress = Double(enrichedCount) / Double(totalToEnrich)
                    statusMessage = "Fetching metadata \(enrichedCount)/\(totalToEnrich)"
                    pendingCount = 0
                }

                if index < needsBothList.count {
                    launch(needsBothList[index], flag: rateLimitFlag)
                    index += 1
                }
            }
            // Flush any remaining
            if pendingCount > 0 {
                enrichedCount += pendingCount
                progress = Double(enrichedCount) / Double(totalToEnrich)
                statusMessage = "Fetching metadata \(enrichedCount)/\(totalToEnrich)"
            }
        }

        // Step 4b: Fetch OMDb-only (items that already have TMDB cached)
        let needsOMDBList = needsOMDBOnly
        let stillHealthy = await !rateLimitFlag.isLimited()
        if omdbEnabled && !needsOMDBList.isEmpty && stillHealthy {
            await withTaskGroup(of: MediaEnrichment?.self) { group in
                var index = 0

                func launch(_ work: (tmdbID: String, imdbID: String, existing: MediaEnrichment), flag: OMDBRateLimitFlag) -> Void {
                    let existing = work.existing
                    let imdbID = work.imdbID
                    group.addTask {
                        if await flag.isLimited() { return nil }
                        do {
                            let omdbResult = try await omdbService.fetch(imdbID: imdbID)
                            return existing.merging(omdb: omdbResult)
                        } catch OMDBService.OMDBError.rateLimited {
                            print("[Enrichment] OMDb rate limit hit during backfill, stopping")
                            await flag.mark()
                            return nil
                        } catch OMDBService.OMDBError.notFound {
                            return nil
                        } catch OMDBService.OMDBError.httpError(let code) {
                            if code == 401 || code == 403 || code == 429 || code >= 500 {
                                print("[Enrichment] OMDb backfill disabled for session (HTTP \(code))")
                                await flag.mark()
                            }
                            return nil
                        } catch {
                            print("[Enrichment] OMDb backfill failed \(imdbID): \(error)")
                            return nil
                        }
                    }
                }

                while index < maxConcurrency && index < needsOMDBList.count {
                    launch(needsOMDBList[index], flag: rateLimitFlag)
                    index += 1
                }

                var pendingCount = 0
                for await result in group {
                    if let enrichment = result {
                        newEnrichments.append(enrichment)
                        cache[enrichment.tmdbID] = enrichment
                    }
                    pendingCount += 1

                    if pendingCount >= 5 || (enrichedCount + pendingCount) >= totalToEnrich {
                        enrichedCount += pendingCount
                        progress = Double(enrichedCount) / Double(totalToEnrich)
                        statusMessage = "Fetching metadata \(enrichedCount)/\(totalToEnrich)"
                        pendingCount = 0
                    }

                    if index < needsOMDBList.count {
                        launch(needsOMDBList[index], flag: rateLimitFlag)
                        index += 1
                    }
                }
                if pendingCount > 0 {
                    enrichedCount += pendingCount
                    progress = Double(enrichedCount) / Double(totalToEnrich)
                    statusMessage = "Fetching metadata \(enrichedCount)/\(totalToEnrich)"
                }
            }
        }

        // Step 5: Persist to Supabase
        if !newEnrichments.isEmpty {
            statusMessage = "Saving metadata cache"
            do {
                try await supabase.upsertEnrichments(newEnrichments)
                print("[Enrichment] Saved \(newEnrichments.count) enrichments to Supabase")
            } catch {
                print("[Enrichment] Supabase save failed: \(error)")
            }
        }

        let totalCached = cache.count
        let totalWithOMDB = cache.values.filter { $0.imdbRating != nil }.count
        print("[Enrichment] Complete: \(totalCached) cached total, \(totalWithOMDB) with OMDb data, \(newEnrichments.count) new this session")
        statusMessage = ""
        progress = 1
        isEnriching = false
    }
}
