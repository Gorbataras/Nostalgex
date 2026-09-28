// Channel coverage — inverts the snapshot's per-channel pools into a per-item
// view so you can answer "is every item in my library being pulled into at
// least one channel, and if not, why not?"
//
// Reads only the snapshot (built by build-snapshot.mjs) plus the manifest and
// channels.json. No Plex, no TMDB calls.
//
// Honesty note, because it matters for how the numbers are read: the snapshot
// is produced by the shared JS filter, not by the tvOS app. That filter cannot
// evaluate networks / excludeNetworks / excludeKeywords / ratingMin, only
// partially evaluates studios and productionCompanies, and keyword enrichment
// runs for movies only. So "in zero channels" here is a LOWER BOUND on the
// app's real coverage: every orphan is a candidate to check, not a confirmed
// gap. Orphans that are explained by a tool blind spot are separated out so
// they don't get mistaken for real gaps.

import { unsupportedRulesFor, partialRulesFor, itemPasses } from "./channels.mjs";

const LIMITATION_TV_KEYWORDS = "tv-no-keyword-enrichment";
const LIMITATION_BLIND_SPOT = "blind-spot-channel";

// Rules this tool cannot evaluate. If an orphan passes a channel once these
// are removed from that channel's rules, the app may well pool it there, so
// it is a tool limitation, not a real gap.
const BLIND_RULE_KEYS = ["networks", "excludeNetworks", "excludeKeywords", "ratingMin"];

function blindSpotChannelsFor(item, cfgChannels, manifest, nowSec) {
  const hits = [];
  for (const ch of cfgChannels) {
    const r = ch.rules || {};
    const blind = BLIND_RULE_KEYS.filter((k) => (Array.isArray(r[k]) ? r[k].length : r[k] != null));
    if (!blind.length) continue;
    const relaxed = { ...r };
    for (const k of blind) delete relaxed[k];
    const res = itemPasses(item, { ...ch, rules: relaxed }, { manifest, nowSec });
    if (res && (res === true || res.pass)) hits.push({ id: ch.id, name: ch.name, number: ch.number, via: blind.join("+") });
  }
  return hits;
}

// Order matters: the first flag that applies becomes the item's "likely reason".
// Data-quality reasons come before tool limitations so a genuinely broken item
// (no TMDB match in Plex) isn't hidden behind "the tool can't tell".
const REASONS = [
  { id: "no-tmdb-id",   label: "No TMDB id from Plex",          test: (it) => !it.tmdbID,
    hint: "Plex never matched this item to TMDB, so manifest claims and keyword rules can't reach it. Fix the match in Plex (⋯ → Match) and rescan." },
  { id: "no-genres",    label: "No genres in Plex",             test: (it) => !it.genres || it.genres.length === 0,
    hint: "Most channels gate on genre. Refresh metadata in Plex, or check the agent has genre tags enabled for this library." },
  { id: "no-year",      label: "No year in Plex",               test: (it) => !it.year,
    hint: "Decade channels (80s, 90s…) need a year. Fix the match or edit the year in Plex." },
  { id: LIMITATION_TV_KEYWORDS, label: "TV item: tool has no keyword data", test: (it) => it.type === "episode" && !(it.tmdbKeywords && it.tmdbKeywords.length),
    hint: "TOOL LIMITATION, not necessarily a real gap. build-snapshot only fetches TMDB keywords for movies, so keyword-driven TV channels under-populate here. The app may well pull this in.", limitation: true },
  { id: LIMITATION_BLIND_SPOT, label: "Would pass a channel this tool can't evaluate", test: (it) => Boolean(it._blindSpot && it._blindSpot.length),
    hint: "TOOL LIMITATION. Once the networks / ratingMin / excludeKeywords rules are set aside, this item passes at least one channel that uses them. The app evaluates those rules with TMDB/OMDb data this tool doesn't have, so it is probably pooled there. The channels are listed per item.", limitation: true },
  { id: "no-genre-match", label: "Has metadata, matched nothing", test: () => true,
    hint: "Item has an id, genres and a year but no channel's rules or manifest claims accept it. Either the lineup has no home for this kind of item, or a rule is tighter than intended." },
];

function pick(it) {
  return {
    title: it.displayTitle || it.title,
    showTitle: it.title,
    type: it.type,
    librarySource: it.librarySource,
    year: it.year ?? null,
    genres: it.genres || [],
    tmdbID: it.tmdbID ?? null,
    contentRating: it.contentRating ?? null,
    duration: it.duration ?? null,
    hasKeywords: Boolean(it.tmdbKeywords && it.tmdbKeywords.length),
  };
}

function manifestClaimsFor(it, manifest) {
  if (!manifest?.items || !it.tmdbID) return [];
  const mediaType = it.type === "episode" ? "tv" : "movie";
  const entry = manifest.items[`${mediaType}:${it.tmdbID}`];
  return entry?.channels ? [...entry.channels] : [];
}

export function coverageFromSnapshot(snapshot, manifest, cfgChannels = []) {
  const items = snapshot.items || {};
  const nowSec = Math.floor(Date.now() / 1000);
  const channels = snapshot.channels || [];
  const cfgById = new Map(cfgChannels.map((c) => [c.id, c]));
  const nameById = new Map(channels.map((c) => [c.id, { name: c.name, number: c.number }]));

  // item ratingKey → channel ids that pool it
  const poolsByKey = new Map();
  for (const ch of channels) {
    for (const k of ch.poolKeys || []) {
      let arr = poolsByKey.get(k);
      if (!arr) { arr = []; poolsByKey.set(k, arr); }
      arr.push(ch.id);
    }
  }

  const rows = [];
  const distribution = {}; // "0","1","2","3","4","5+"
  const bySource = {};     // librarySource → { total, orphans }
  const byType = {};       // type → { total, orphans }
  let orphanCount = 0;
  let limitationOrphans = 0;
  let claimedButUnpooled = 0;
  const reasonCounts = Object.fromEntries(REASONS.map((r) => [r.id, 0]));

  for (const [key, it] of Object.entries(items)) {
    const chans = poolsByKey.get(key) || [];
    const n = chans.length;
    const bucket = n >= 5 ? "5+" : String(n);
    distribution[bucket] = (distribution[bucket] || 0) + 1;

    const src = it.librarySource || "unknown";
    const typ = it.type || "unknown";
    bySource[src] = bySource[src] || { total: 0, orphans: 0 };
    byType[typ] = byType[typ] || { total: 0, orphans: 0 };
    bySource[src].total++;
    byType[typ].total++;

    const row = { key, ...pick(it), channelCount: n, channels: chans };

    if (n === 0) {
      orphanCount++;
      // Only computed for orphans: it runs the filter once per blind-spot channel.
      it._blindSpot = blindSpotChannelsFor(it, cfgChannels, manifest, nowSec);
      if (it._blindSpot.length) row.blindSpotChannels = it._blindSpot;
      bySource[src].orphans++;
      byType[typ].orphans++;
      const reason = REASONS.find((r) => r.test(it));
      row.reason = reason.id;
      row.limitation = Boolean(reason.limitation);
      if (reason.limitation) limitationOrphans++;
      reasonCounts[reason.id]++;
      // A manifest claim that didn't survive into a pool means a channel rule
      // (type, year range, titleContains, genre exclude) vetoed it. That's a
      // strong "look here" signal.
      const claims = manifestClaimsFor(it, manifest);
      if (claims.length) {
        claimedButUnpooled++;
        row.manifestClaims = claims.map((cid) => ({ id: cid, ...(nameById.get(cid) || { name: cfgById.get(cid)?.name || `#${cid}`, number: cfgById.get(cid)?.number ?? null }) }));
      }
    }
    rows.push(row);
  }

  // Channels: size, minItems shortfall, and the rules this tool can't evaluate
  const channelRows = channels.map((c) => {
    const cfg = cfgById.get(c.id);
    const size = (c.poolKeys || []).length;
    const minItems = cfg?.minItems ?? null;
    return {
      id: c.id,
      number: c.number,
      name: c.name,
      category: c.category || cfg?.category || null,
      poolSize: size,
      minItems,
      belowMin: minItems != null && size < minItems,
      unsupportedRules: cfg ? unsupportedRulesFor(cfg) : [],
      partialRules: cfg ? partialRulesFor(cfg) : [],
    };
  }).sort((a, b) => a.poolSize - b.poolSize);

  const totalItems = rows.length;
  return {
    generatedAt: snapshot.generatedAt,
    deviceName: snapshot.deviceName,
    totals: {
      items: totalItems,
      covered: totalItems - orphanCount,
      orphans: orphanCount,
      orphansExplainedByToolLimits: limitationOrphans,
      orphansLikelyReal: orphanCount - limitationOrphans,
      singleChannel: distribution["1"] || 0,
      claimedButUnpooled,
      channels: channels.length,
      channelsBelowMin: channelRows.filter((c) => c.belowMin).length,
      channelsWithBlindSpots: channelRows.filter((c) => c.unsupportedRules.length || c.partialRules.length).length,
    },
    distribution,
    bySource,
    byType,
    reasons: REASONS.map((r) => ({ id: r.id, label: r.label, hint: r.hint, limitation: Boolean(r.limitation), count: reasonCounts[r.id] })),
    channels: channelRows,
    // Every item, so the page can answer "where is X?" without another round trip.
    // ~10k rows of small fields is a couple of MB; fine for a local tool.
    items: rows,
  };
}
