import Foundation

// MARK: - Resolved manifest block (with media item)

struct ManifestBlock {
    let item: PlexMediaItem
    let startTime: Date
    let endTime: Date

    var durationSeconds: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
}

// MARK: - Builds and caches one 24h EPG per channel per local calendar day

enum DailyManifestScheduler {

    // MARK: - In-memory memo
    //
    // A day's blocks are a pure function of (channel pool, day, credentials), but callers
    // are SwiftUI bodies: the mini guide rebuilds a schedule for *every* channel card on
    // every body evaluation, and the body re-evaluates on every focus move. Without this
    // memo each of those rebuilds re-hashes the pool, re-reads the manifest off disk and
    // re-decodes it — tens of milliseconds of main-thread work per remote press.

    private static let memoLock = NSLock()
    private static var memo: [String: [ManifestBlock]] = [:]
    private static var memoOrder: [String] = []
    private static let memoLimit = 256

    private static func memoized(_ key: String) -> [ManifestBlock]? {
        memoLock.lock()
        defer { memoLock.unlock() }
        return memo[key]
    }

    private static func storeMemo(_ blocks: [ManifestBlock], for key: String) {
        memoLock.lock()
        defer { memoLock.unlock() }
        if memo[key] == nil {
            memoOrder.append(key)
            if memoOrder.count > memoLimit {
                memo.removeValue(forKey: memoOrder.removeFirst())
            }
        }
        memo[key] = blocks
    }

    /// Drop the memo. Must be called whenever the on-disk manifests or the channel pools
    /// change underneath it (library reload, manifest wipe), otherwise the guide keeps
    /// serving yesterday's lineup.
    static func invalidateMemo() {
        memoLock.lock()
        defer { memoLock.unlock() }
        memo.removeAll()
        memoOrder.removeAll()
    }

    static func blocks(
        for channel: Channel,
        at now: Date = Date(),
        credentialFingerprint: String,
        calendar: Calendar = .current
    ) -> [ManifestBlock] {
        let pool = channel.filteredPool().filter { $0.duration > 0 }
        guard !pool.isEmpty else { return [] }

        let dayStart = DailyManifestStore.startOfLocalDay(for: now, calendar: calendar)
        let dayKey = DailyManifestStore.localDayKey(for: now, calendar: calendar)

        // Pool shape is part of the key because `filteredPool()` is time-of-day dependent:
        // a channel that gates R-rated content flips pools at a fixed hour and must not
        // keep serving the schedule built from the other pool. Pools that change without
        // changing shape (a library refresh) are covered by `invalidateMemo()`.
        let memoKey = [
            credentialFingerprint,
            String(channel.id),
            dayKey,
            String(pool.count),
            pool.first?.id ?? "",
            pool.last?.id ?? ""
        ].joined(separator: "|")
        if let hit = memoized(memoKey) { return hit }

        let poolFP = DailyManifestStore.poolFingerprint(ratingKeys: pool.map(\.id))

        if let cached = DailyManifestStore.load(
            channelId: channel.id,
            dayKey: dayKey,
            credentialFingerprint: credentialFingerprint,
            expectedPoolFingerprint: poolFP
        ) {
            let resolved = resolveBlocks(cached.blocks, pool: pool)
            storeMemo(resolved, for: memoKey)
            return resolved
        }

        let dayNumber = DailyManifestStore.localDayNumber(for: now, calendar: calendar)
        let yesterdayKey = DailyManifestStore.localDayKey(
            for: dayStart.addingTimeInterval(-86400),
            calendar: calendar
        )
        let yesterdayAired = DailyManifestStore.airedRatingKeys(
            channelId: channel.id,
            dayKey: yesterdayKey,
            credentialFingerprint: credentialFingerprint
        )
        let yesterdayLastItemID = DailyManifestStore.lastAiredRatingKey(
            channelId: channel.id,
            dayKey: yesterdayKey,
            credentialFingerprint: credentialFingerprint
        )

        let packed = packDay(
            pool: pool,
            dayStart: dayStart,
            dayNumber: dayNumber,
            channelId: channel.id,
            isPremiereChannel: channel.isPremiereChannel,
            yesterdayAiredKeys: yesterdayAired,
            yesterdayLastItemID: yesterdayLastItemID
        )

        let stored = packed.map {
            StoredManifestBlock(
                ratingKey: $0.item.id,
                startUnix: Int($0.startTime.timeIntervalSince1970),
                endUnix: Int($0.endTime.timeIntervalSince1970)
            )
        }

        let file = DailyManifestFile(
            schemaVersion: 1,
            channelId: channel.id,
            dayKey: dayKey,
            credentialFingerprint: credentialFingerprint,
            poolFingerprint: poolFP,
            blocks: stored
        )
        DailyManifestStore.save(file)
        storeMemo(packed, for: memoKey)

        return packed
    }

    static func blocksInRange(
        for channel: Channel,
        from: Date,
        to: Date,
        credentialFingerprint: String,
        calendar: Calendar = .current
    ) -> [ManifestBlock] {
        var result: [ManifestBlock] = []
        var cursor = DailyManifestStore.startOfLocalDay(for: from, calendar: calendar)
        let endDay = DailyManifestStore.startOfLocalDay(for: to, calendar: calendar)

        while cursor <= endDay {
            let dayBlocks = blocks(
                for: channel,
                at: cursor.addingTimeInterval(3600),
                credentialFingerprint: credentialFingerprint,
                calendar: calendar
            )
            for block in dayBlocks where block.endTime > from && block.startTime < to {
                result.append(block)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        return result.sorted { $0.startTime < $1.startTime }
    }

    // MARK: - Packing

    private static func packDay(
        pool: [PlexMediaItem],
        dayStart: Date,
        dayNumber: Int,
        channelId: Int,
        isPremiereChannel: Bool,
        yesterdayAiredKeys: Set<String>,
        yesterdayLastItemID: String?
    ) -> [ManifestBlock] {
        let dayEnd = dayStart.addingTimeInterval(86400)
        let totalPoolSec = pool.reduce(0) { $0 + $1.duration * 60 }
        guard totalPoolSec > 0 else { return [] }

        let unplayed = pool.filter { !yesterdayAiredKeys.contains($0.id) }
        let dayStartUnix = Int(dayStart.timeIntervalSince1970)
        // Interleave for variety, then reunite multi-part stories. On the premiere
        // channel only, this week's additions are first slotted at the prime-time anchor
        // so they air while people are watching - and because that runs before the
        // sequel grouping, a just-added Part 1 drags its Part 2 with it.
        //
        // Every other channel skips the promotion: a new title is in several pools, and
        // promoting it on each one is what made Point Break premiere on five channels at
        // the same moment. Elsewhere it just enters the rotation.
        let interleaved = SchedulePoolOrdering.interleaveByShow(
            unplayed, seed: channelId, dayNumber: dayNumber
        )
        let promoted = isPremiereChannel
            ? SchedulePoolOrdering.promoteRecentlyAdded(
                interleaved,
                dayStartUnix: dayStartUnix,
                channelId: channelId
              )
            : interleaved
        var unplayedOrdered = SchedulePoolOrdering.groupSequelParts(promoted)

        // Cross-day seam: this function only ever sees one day at a time, so with no
        // guard here, whatever the pool ordering picks to lead off today has no idea it
        // might be the exact title that just finished airing seconds before midnight --
        // the same coincidence as the wraparound seam below, one level up. Move it later
        // in today's order instead of opening the day with a repeat.
        if let yesterdayLastItemID, unplayedOrdered.count > 1,
           unplayedOrdered.first?.id == yesterdayLastItemID {
            let duplicate = unplayedOrdered.removeFirst()
            unplayedOrdered.append(duplicate)
        }

        var blocks: [ManifestBlock] = []
        var t = dayStart

        for item in unplayedOrdered {
            guard t < dayEnd else { break }
            let dur = TimeInterval(item.duration * 60)
            guard dur > 0 else { continue }
            let end = t.addingTimeInterval(dur)
            blocks.append(ManifestBlock(item: item, startTime: t, endTime: end))
            t = end
        }

        if t < dayEnd {
            let orderedFull = SchedulePoolOrdering.groupSequelParts(
                SchedulePoolOrdering.interleaveByShow(pool, seed: channelId, dayNumber: dayNumber &+ 1)
            )
            let goldenShift = Int(Double(totalPoolSec) * 0.6180339887)
            let offsetSec = (dayNumber * goldenShift) % totalPoolSec

            var posInLoop = offsetSec
            var cycleIndex = 0
            var elapsed = 0
            for i in 0..<orderedFull.count {
                let d = orderedFull[i].duration * 60
                if elapsed + d > offsetSec {
                    cycleIndex = i
                    posInLoop = offsetSec - elapsed
                    break
                }
                elapsed += d
            }

            // The golden-ratio offset picks an arbitrary starting point in the full pool
            // with no idea what the primary pass just finished playing. On a small pool --
            // most of this app's niche channels: MINION HQ, BUDDIES, DIZNEY TOONS, DIZ
            // FLICKS, LAST ACTION HEROES -- the primary pass exhausts within a couple of
            // hours, so this wraparound path runs on nearly every day, and the offset
            // landing on the same title that just finished is common, not rare: the same
            // film played twice back to back with zero gap (Toy Story, Cobra, Waterworld,
            // Heavyweights, Dirty Dancing all reproduced this on device). If the seam lands
            // on a repeat, start from the next item instead.
            // Falls back to yesterday's last item when blocks is still empty here: that
            // happens only when today's primary pass placed nothing at all (an empty or
            // fully-exhausted unplayed pool), in which case the wraparound's first pick
            // *is* the item opening the day across the midnight boundary, and the cross-day
            // guard above never got a chance to run because there was nothing to reorder.
            if orderedFull.count > 1, let lastPlayed = blocks.last?.item.id ?? yesterdayLastItemID,
               orderedFull[cycleIndex].id == lastPlayed {
                cycleIndex = (cycleIndex + 1) % orderedFull.count
                posInLoop = 0
            }

            var idx = cycleIndex
            var offsetInItem = posInLoop

            while t < dayEnd {
                let item = orderedFull[idx % orderedFull.count]
                let fullDur = item.duration * 60
                guard fullDur > 0 else {
                    idx += 1
                    offsetInItem = 0
                    continue
                }

                let remainingInItem = fullDur - offsetInItem
                let remainingDay = Int(dayEnd.timeIntervalSince(t))
                let playSec = min(remainingInItem, remainingDay)
                guard playSec > 0 else {
                    idx += 1
                    offsetInItem = 0
                    continue
                }

                let end = t.addingTimeInterval(TimeInterval(playSec))
                blocks.append(ManifestBlock(item: item, startTime: t, endTime: end))
                t = end

                if offsetInItem + playSec >= fullDur {
                    idx += 1
                    offsetInItem = 0
                } else {
                    offsetInItem += playSec
                }
            }
        }

        return blocks
    }

    private static func resolveBlocks(_ stored: [StoredManifestBlock], pool: [PlexMediaItem]) -> [ManifestBlock] {
        let lookup = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return stored.compactMap { row in
            guard let item = lookup[row.ratingKey] else { return nil }
            return ManifestBlock(
                item: item,
                startTime: Date(timeIntervalSince1970: Double(row.startUnix)),
                endTime: Date(timeIntervalSince1970: Double(row.endUnix))
            )
        }
    }
}
