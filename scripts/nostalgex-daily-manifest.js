// Daily 24h EPG manifests — mirrors tvOS DailyManifestScheduler (unplayed-first per day).
//
// PARITY CONTRACT with tvOS
//   Nostalgex/Nostalgex/Models/SchedulePoolOrdering.swift
//   Nostalgex/Nostalgex/Services/DailyManifestScheduler.swift
//   Nostalgex/Nostalgex/Services/DailyManifestStore.swift
//
// The running order for a given (pool, channelId, local day) is reproduced
// bit-for-bit here: same splitmix64 seeding, same xorshift64 stream, same
// Swift-stdlib shuffle (Lemire nearly-divisionless bounded draw), same grouping
// key, same premiere promotion, same sequel grouping, same golden-ratio filler
// offset. Verified by comparing against a Swift harness running the real
// SeededRNG + Array.shuffle(using:).
//
// KNOWN REMAINING DIFFERENCES (deliberate, cannot be closed from the browser):
//  1. `poolFingerprint` is a cheap string hash here vs SHA-256 on tvOS. It only
//     decides whether a *locally cached* manifest is still valid; it never feeds
//     the ordering. Caches are per-device anyway.
//  2. Cache storage is localStorage keyed by serverKey, not the tvOS
//     Application Support files keyed by credential fingerprint. Same role,
//     different medium.
//  3. `promoteRecentlyAdded` needs `item.addedAt`. The Plex loader in
//     plex-tuner.html supplies it; the Jellyfin and Emby loaders currently hard-code
//     `addedAt: 0`, so premieres never trigger on those servers on the web. That is
//     a plex-tuner.html data-shape gap, not an ordering gap — fix it there.
//  4. `localDayNumber` uses Math.floor where Swift uses Int() truncation. Identical
//     for every post-1970 timestamp; they would only diverge before the epoch.
(function (global) {
  'use strict';

  const MANIFEST_PREFIX = 'plex90_manifest_';
  const SCHEMA_VERSION = 1;
  const MASK64 = 0xFFFFFFFFFFFFFFFFn;

  /** Mirrors `splitmix64` in SchedulePoolOrdering.swift. */
  function splitmix64(x) {
    let z = (BigInt(x) + 0x9E3779B97F4A7C15n) & MASK64;
    z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & MASK64;
    z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & MASK64;
    z = (z ^ (z >> 31n)) & MASK64;
    return z;
  }

  /**
   * Mirrors Swift `SeededRNG`: splitmix64-seeded xorshift64.
   * `boundedNext` mirrors the Swift stdlib's
   * `RandomNumberGenerator.next(upperBound:)` (Lemire nearly-divisionless), which
   * `Array.shuffle(using:)` calls. Both are required for bit-identical shuffles —
   * the previous implementation iterated splitmix64 and used a float draw, which
   * produced a completely different order from tvOS.
   */
  function makeSeededRNG(seed) {
    let state = splitmix64(seed);
    if (state === 0n) state = 1n;
    function next() {
      state = (state ^ ((state << 13n) & MASK64)) & MASK64;
      state = state ^ (state >> 7n);
      state = (state ^ ((state << 17n) & MASK64)) & MASK64;
      return state;
    }
    function boundedNext(upperBound) {
      const u = BigInt(upperBound);
      let m = next() * u;
      let low = m & MASK64;
      if (low < u) {
        const t = ((0n - u) & MASK64) % u;
        while (low < t) {
          m = next() * u;
          low = m & MASK64;
        }
      }
      return Number(m >> 64n);
    }
    return { next, boundedNext };
  }

  /** Mirrors Swift stdlib `MutableCollection.shuffle(using:)`. In place. */
  function swiftShuffle(arr, rng) {
    let amount = arr.length;
    let currentIndex = 0;
    while (amount > 1) {
      const random = rng.boundedNext(amount);
      amount -= 1;
      const j = currentIndex + random;
      const tmp = arr[currentIndex];
      arr[currentIndex] = arr[j];
      arr[j] = tmp;
      currentIndex += 1;
    }
    return arr;
  }

  function interleaveByShow(items, seed, dayNumber) {
    if (items.length <= 1) return items.slice();

    const groups = new Map();
    for (const item of items) {
      // Swift keys episodes on `item.title`, which IS the show title on a
      // PlexMediaItem (episode name lives in `episodeTitle`). The web items use
      // the same shape. The old `item.grandparentTitle` lookup was always
      // undefined here, so every episode became its own group and the
      // "max 2 in a row" interleave did nothing.
      const key = item.type === 'episode' ? item.title : `movie_${item.ratingKey}`;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(item);
    }

    const rng = makeSeededRNG(BigInt(Math.abs(seed) + 1) + BigInt(dayNumber));

    for (const list of groups.values()) swiftShuffle(list, rng);

    const orderedGroups = [...groups.values()];
    swiftShuffle(orderedGroups, rng);

    const maxConsecutive = 2;
    const result = [];
    const positions = orderedGroups.map(() => 0);
    let groupIndex = 0;
    let exhausted = 0;

    while (exhausted < orderedGroups.length) {
      let attempts = 0;
      while (positions[groupIndex] >= orderedGroups[groupIndex].length) {
        groupIndex = (groupIndex + 1) % orderedGroups.length;
        attempts++;
        if (attempts > orderedGroups.length) break;
      }
      if (attempts > orderedGroups.length) break;

      const group = orderedGroups[groupIndex];
      const pos = positions[groupIndex];
      const take = Math.min(maxConsecutive, group.length - pos);
      for (let i = 0; i < take; i++) result.push(group[pos + i]);
      positions[groupIndex] = pos + take;
      if (positions[groupIndex] >= group.length) exhausted++;
      groupIndex = (groupIndex + 1) % orderedGroups.length;
    }

    return result;
  }

  // ── Recently-added priority ("premieres") ────────────────────────────────
  // Mirrors SchedulePoolOrdering.promoteRecentlyAdded.

  /** A week of recency earns priority placement. */
  const PREMIERE_WINDOW_SECONDS = 7 * 86400;
  /** 7 PM: where the premiere window starts (prime time, not midnight). */
  const PREMIERE_ANCHOR_SECONDS = 19 * 3600;
  /**
   * 19:00-24:00 in 15-minute steps. A constant anchor put a film added to six
   * channels at 19:00 on all six, so the guide showed it six times in the same
   * slot. Slots are derived per (channel, item) instead.
   */
  const PREMIERE_SPREAD_SECONDS = 5 * 3600;
  const PREMIERE_SLOT_SECONDS = 15 * 60;

  /** Mirrors SchedulePoolOrdering.premiereOffset: FNV-1a over the ratingKey, murmur3 finalizer. */
  function premiereOffset(channelId, ratingKey) {
    const slots = BigInt(Math.max(1, Math.floor(PREMIERE_SPREAD_SECONDS / PREMIERE_SLOT_SECONDS)));
    let x = (BigInt.asUintN(64, BigInt(channelId)) + 0x9E3779B97F4A7C15n) & MASK64;
    for (const byte of new TextEncoder().encode(ratingKey)) {
      x = ((x ^ BigInt(byte)) * 0x00000100000001B3n) & MASK64;
    }
    x = x ^ (x >> 33n);
    x = (x * 0xFF51AFD7ED558CCDn) & MASK64;
    x = x ^ (x >> 33n);
    return PREMIERE_ANCHOR_SECONDS + Number(x % slots) * PREMIERE_SLOT_SECONDS;
  }

  function promoteRecentlyAdded(items, dayStartUnix, channelId, windowSeconds) {
    if (items.length <= 1) return items;
    const window = windowSeconds == null ? PREMIERE_WINDOW_SECONDS : windowSeconds;
    const cutoff = dayStartUnix - window;
    const isRecent = (i) => (i.addedAt || 0) > 0 && (i.addedAt || 0) >= cutoff;
    const recent = items.filter(isRecent);
    if (!recent.length || recent.length >= items.length) return items;
    const rest = items.filter((i) => !isRecent(i));

    // Ascending by target so earlier premieres are placed first; the cumulative
    // walk below then counts the ones already inserted, and two premieres an hour
    // apart stay an hour apart instead of stacking. ratingKey breaks ties.
    const targets = recent.map((item) => ({ item, offset: premiereOffset(channelId, item.ratingKey) }));
    targets.sort((a, b) => {
      if (a.offset !== b.offset) return a.offset - b.offset;
      return a.item.ratingKey < b.item.ratingKey ? -1 : a.item.ratingKey > b.item.ratingKey ? 1 : 0;
    });

    const out = rest.slice();
    for (const target of targets) {
      let insertAt = out.length;
      let cumulativeSeconds = 0;
      for (let index = 0; index < out.length; index++) {
        if (cumulativeSeconds >= target.offset) { insertAt = index; break; }
        cumulativeSeconds += (out[index].duration || 0) * 60;
      }
      out.splice(insertAt, 0, target.item);
    }
    return out;
  }

  // ── Sequel-part adjacency ────────────────────────────────────────────────
  // Mirrors SchedulePoolOrdering.groupSequelParts. Anchored to the END of the
  // title so mid-title words never match.
  const SEQUEL_MARKER = /^(.*?)[\s:,-]+(?:part|pt\.?)\s*([0-9]{1,2})\s*$/i;

  function groupSequelParts(items) {
    if (items.length <= 1) return items;

    const marked = [];
    for (let index = 0; index < items.length; index++) {
      const it = items[index];
      if (it.type !== 'movie') continue;
      const match = SEQUEL_MARKER.exec(it.title || '');
      if (!match) continue;
      const ordinal = parseInt(match[2], 10);
      if (!Number.isFinite(ordinal)) continue;
      const base = match[1].toLowerCase().trim();
      if (!base) continue;
      marked.push({ index, base, ordinal });
    }

    const groups = new Map();
    for (const mark of marked) {
      if (!groups.has(mark.base)) groups.set(mark.base, []);
      groups.get(mark.base).push(mark);
    }
    // Only real multi-part stories move; a lone "Part 2" stays put.
    const families = [...groups.values()].filter((f) => f.length > 1);
    if (!families.length) return items;

    const pulled = new Set();
    const insertions = new Map();
    for (const family of families) {
      const anchor = Math.min(...family.map((m) => m.index));
      const ordered = family
        .slice()
        .sort((a, b) => a.ordinal - b.ordinal)
        .map((m) => items[m.index]);
      for (const member of family) pulled.add(member.index);
      insertions.set(anchor, ordered);
    }

    const result = [];
    for (let index = 0; index < items.length; index++) {
      if (insertions.has(index)) result.push(...insertions.get(index));
      else if (!pulled.has(index)) result.push(items[index]);
    }
    return result;
  }

  function localDayKey(dateMs) {
    const d = new Date(dateMs);
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${y}-${m}-${day}`;
  }

  function startOfLocalDayMs(dateMs) {
    const d = new Date(dateMs);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
  }

  function localDayNumber(dateMs) {
    return Math.floor(startOfLocalDayMs(dateMs) / 86400000);
  }

  function poolFingerprint(pool) {
    const keys = pool.map(i => i.ratingKey).sort().join(',');
    let h = 0;
    for (let i = 0; i < keys.length; i++) {
      h = ((h << 5) - h + keys.charCodeAt(i)) | 0;
    }
    return String(h);
  }

  function storageKey(serverKey, channelId, dayKey) {
    return `${MANIFEST_PREFIX}${serverKey}_${channelId}_${dayKey}`;
  }

  function loadManifest(serverKey, channelId, dayKey, poolFP) {
    try {
      const raw = localStorage.getItem(storageKey(serverKey, channelId, dayKey));
      if (!raw) return null;
      const manifest = JSON.parse(raw);
      if (manifest.schemaVersion !== SCHEMA_VERSION || manifest.poolFingerprint !== poolFP) return null;
      return manifest;
    } catch {
      return null;
    }
  }

  function saveManifest(serverKey, manifest) {
    try {
      localStorage.setItem(
        storageKey(serverKey, manifest.channelId, manifest.dayKey),
        JSON.stringify(manifest)
      );
    } catch { /* quota */ }
  }

  function airedRatingKeys(serverKey, channelId, dayKey) {
    try {
      const raw = localStorage.getItem(storageKey(serverKey, channelId, dayKey));
      if (!raw) return new Set();
      const manifest = JSON.parse(raw);
      return new Set((manifest.blocks || []).map(b => b.ratingKey));
    } catch {
      return new Set();
    }
  }

  function lastAiredRatingKey(serverKey, channelId, dayKey) {
    try {
      const raw = localStorage.getItem(storageKey(serverKey, channelId, dayKey));
      if (!raw) return null;
      const blocks = JSON.parse(raw).blocks || [];
      return blocks.length ? blocks[blocks.length - 1].ratingKey : null;
    } catch {
      return null;
    }
  }

  function packDay(pool, dayStartSec, dayNumber, channelId, yesterdayAired, isPremiereChannel, yesterdayLastRatingKey) {
    const dayEndSec = dayStartSec + 86400;
    const totalPoolSec = pool.reduce((s, i) => s + (i.duration || 0) * 60, 0);
    if (totalPoolSec <= 0) return [];

    const unplayed = pool.filter(i => !yesterdayAired.has(i.ratingKey));
    // Interleave for variety, then slot this week's additions at the prime-time
    // anchor so they air while people are watching, then reunite multi-part
    // stories — in that order, so a just-added Part 1 drags its Part 2 with it.
    // Same nesting as DailyManifestScheduler.packDay.
    // Premiere promotion is per-channel on purpose: promoting a new arrival on
    // every channel that carries it made one film premiere on five channels at
    // the same moment. Mirrors DailyManifestScheduler.packDay.
    const interleaved = interleaveByShow(unplayed, channelId, dayNumber);
    const promoted = isPremiereChannel
      ? promoteRecentlyAdded(interleaved, dayStartSec, channelId)
      : interleaved;
    const unplayedOrdered = groupSequelParts(promoted);

    // Cross-day seam: this function only sees one day at a time, so without this
    // guard whatever leads off today has no idea it might be the exact title that
    // finished seconds before midnight.
    if (yesterdayLastRatingKey && unplayedOrdered.length > 1 &&
        unplayedOrdered[0].ratingKey === yesterdayLastRatingKey) {
      unplayedOrdered.push(unplayedOrdered.shift());
    }
    const blocks = [];
    let t = dayStartSec;

    for (const item of unplayedOrdered) {
      if (t >= dayEndSec) break;
      const dur = (item.duration || 0) * 60;
      if (dur <= 0) continue;
      blocks.push({ ratingKey: item.ratingKey, startSec: t, endSec: t + dur });
      t += dur;
    }

    if (t < dayEndSec) {
      // Filler loop: no premiere promotion on tvOS either — sequels only.
      const orderedFull = groupSequelParts(interleaveByShow(pool, channelId, dayNumber + 1));
      const goldenShift = Math.floor(totalPoolSec * 0.6180339887);
      const offsetSec = (dayNumber * goldenShift) % totalPoolSec;

      let elapsed = 0;
      let cycleIndex = 0;
      let offsetInItem = offsetSec;
      for (let i = 0; i < orderedFull.length; i++) {
        const d = (orderedFull[i].duration || 0) * 60;
        if (elapsed + d > offsetSec) {
          cycleIndex = i;
          offsetInItem = offsetSec - elapsed;
          break;
        }
        elapsed += d;
      }

      // Wraparound seam: the cycle can land on the very item that just played.
      if (orderedFull.length > 1) {
        const lastPlayed = blocks.length ? blocks[blocks.length - 1].ratingKey : yesterdayLastRatingKey;
        if (lastPlayed && orderedFull[cycleIndex].ratingKey === lastPlayed) {
          cycleIndex = (cycleIndex + 1) % orderedFull.length;
          offsetInItem = 0;
        }
      }

      let idx = cycleIndex;
      while (t < dayEndSec) {
        const item = orderedFull[idx % orderedFull.length];
        const fullDur = (item.duration || 0) * 60;
        if (fullDur <= 0) {
          idx++;
          offsetInItem = 0;
          continue;
        }
        const remainingInItem = fullDur - offsetInItem;
        const remainingDay = dayEndSec - t;
        const playSec = Math.min(remainingInItem, remainingDay);
        if (playSec <= 0) {
          idx++;
          offsetInItem = 0;
          continue;
        }
        blocks.push({ ratingKey: item.ratingKey, startSec: t, endSec: t + playSec });
        t += playSec;
        if (offsetInItem + playSec >= fullDur) {
          idx++;
          offsetInItem = 0;
        } else {
          offsetInItem += playSec;
        }
      }
    }

    return blocks;
  }

  function resolveBlocks(storedBlocks, pool) {
    const lookup = new Map(pool.map(i => [i.ratingKey, i]));
    return storedBlocks
      .map(b => {
        const item = lookup.get(b.ratingKey);
        if (!item) return null;
        return { item, startSec: b.startSec, endSec: b.endSec };
      })
      .filter(Boolean);
  }

  function getManifestBlocks(channel, pool, atMs, serverKey) {
    const validPool = pool.filter(i => i && (i.duration || 0) > 0);
    if (!validPool.length) return [];

    const dayStartSec = Math.floor(startOfLocalDayMs(atMs) / 1000);
    const dayKey = localDayKey(atMs);
    const poolFP = poolFingerprint(validPool);
    const channelId = channel.id;

    const cached = loadManifest(serverKey, channelId, dayKey, poolFP);
    if (cached) return resolveBlocks(cached.blocks, validPool);

    const dayNumber = localDayNumber(atMs);
    const yesterdayKey = localDayKey(dayStartSec * 1000 - 86400000);
    const yesterdayAired = airedRatingKeys(serverKey, channelId, yesterdayKey);

    const yesterdayLast = lastAiredRatingKey(serverKey, channelId, yesterdayKey);
    const packed = packDay(validPool, dayStartSec, dayNumber, channelId, yesterdayAired,
                           Boolean(channel.isPremiereChannel), yesterdayLast);
    saveManifest(serverKey, {
      schemaVersion: SCHEMA_VERSION,
      channelId,
      dayKey,
      poolFingerprint: poolFP,
      blocks: packed,
    });

    return resolveBlocks(packed, validPool);
  }

  function clearManifests(serverKey) {
    try {
      const prefix = `${MANIFEST_PREFIX}${serverKey}_`;
      const toRemove = [];
      for (let i = 0; i < localStorage.length; i++) {
        const key = localStorage.key(i);
        if (key && key.startsWith(prefix)) toRemove.push(key);
      }
      toRemove.forEach(k => localStorage.removeItem(k));
    } catch { /* ignore */ }
  }

  const api = {
    getManifestBlocks,
    clearManifests,
    interleaveByShow,
    promoteRecentlyAdded,
    premiereOffset,
    groupSequelParts,
    packDay,
    localDayNumber,
    localDayKey,
    startOfLocalDayMs,
  };

  global.NostalgexDailyManifest = api;
  // Node (tests/devtools) — the browser keeps loading this as a plain script.
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') {
    module.exports = api;
  }
})(typeof window !== 'undefined' ? window : globalThis);
