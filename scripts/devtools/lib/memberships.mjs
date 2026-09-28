// Devtools helpers for the channel-memberships manifest. Reads the manifest +
// exemplars file from disk on each call (cheap — small files, low traffic on
// the dev UI). Live TMDB lookups happen on demand and need TMDB_API_KEY.

import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PLEX90_ROOT = join(__dirname, "..", "..", "..");
const MANIFEST_PATH = join(PLEX90_ROOT, "channels-memberships.json");
const EXEMPLARS_PATH = join(PLEX90_ROOT, "scripts", "channel-keyword-tuner", "exemplars.json");

const TMDB = "https://api.themoviedb.org/3";

export async function loadManifest() {
  try {
    const raw = await readFile(MANIFEST_PATH, "utf8");
    return JSON.parse(raw);
  } catch {
    return { version: 0, generated: "", minRelatedCount: 0, items: {} };
  }
}

export async function loadExemplars() {
  try {
    const raw = await readFile(EXEMPLARS_PATH, "utf8");
    return JSON.parse(raw);
  } catch {
    return { channels: [] };
  }
}

// Parse "exemplar:Foo" / "recommendation:5 exemplars" / "similar:3 exemplars"
function parseSourceKind(source) {
  if (!source) return "unknown";
  if (source.startsWith("exemplar:")) return "exemplar";
  if (source.startsWith("recommendation:")) return "recommendation";
  if (source.startsWith("similar:")) return "similar";
  return "other";
}

export async function manifestSummary(channelInfoByID) {
  const m = await loadManifest();
  const exemplars = await loadExemplars();
  const exemplarCountByChannel = new Map(exemplars.channels.map((c) => [c.id, c.exemplars.length]));

  const perChannel = new Map();
  for (const [key, entry] of Object.entries(m.items)) {
    const kind = parseSourceKind(entry.source);
    for (const cid of entry.channels) {
      const slot = perChannel.get(cid) || { id: cid, total: 0, exemplar: 0, recommendation: 0, similar: 0 };
      slot.total++;
      slot[kind]++;
      perChannel.set(cid, slot);
    }
  }

  const channels = [...perChannel.values()]
    .map((s) => ({
      id: s.id,
      number: channelInfoByID.get(s.id)?.number ?? s.id,
      name: channelInfoByID.get(s.id)?.name ?? `CH ${s.id}`,
      exemplarsConfigured: exemplarCountByChannel.get(s.id) || 0,
      claimed: s.total,
      breakdown: { exemplar: s.exemplar, recommendation: s.recommendation, similar: s.similar },
    }))
    .sort((a, b) => a.number - b.number);

  return {
    generated: m.generated,
    minRelatedCount: m.minRelatedCount,
    totalItems: Object.keys(m.items).length,
    channels,
  };
}

export async function claimsForChannel(channelID) {
  const m = await loadManifest();
  const items = [];
  for (const [key, entry] of Object.entries(m.items)) {
    if (!entry.channels.includes(channelID)) continue;
    const [mediaType, tmdbID] = key.split(":");
    items.push({
      tmdbID: Number(tmdbID),
      mediaType: entry.mediaType || mediaType,
      name: entry.name || `(unknown — re-run script)`,
      source: entry.source || "",
      kind: parseSourceKind(entry.source),
      otherChannels: entry.channels.filter((c) => c !== channelID),
    });
  }
  // Sort: exemplars first, then recommendations (highest confidence), then similar, alpha within
  const order = { exemplar: 0, recommendation: 1, similar: 2, other: 3, unknown: 4 };
  items.sort((a, b) => (order[a.kind] - order[b.kind]) || a.name.localeCompare(b.name));
  return { channelID, count: items.length, items };
}

export async function conflicts(channelNamesByID) {
  const m = await loadManifest();
  const out = [];
  for (const [key, entry] of Object.entries(m.items)) {
    if (entry.channels.length < 2) continue;
    const [mediaType, tmdbID] = key.split(":");
    out.push({
      tmdbID: Number(tmdbID),
      mediaType: entry.mediaType || mediaType,
      name: entry.name || "(unknown)",
      channels: entry.channels.map((cid) => ({ id: cid, name: channelNamesByID.get(cid) || String(cid) })),
      source: entry.source || "",
    });
  }
  out.sort((a, b) => b.channels.length - a.channels.length || a.name.localeCompare(b.name));
  return { count: out.length, items: out };
}

// --- Live TMDB lookups ---------------------------------------------------

function isBearer(key) { return key.startsWith("eyJ"); }

async function tmdb(pathPart, params = {}, key) {
  const url = new URL(TMDB + pathPart);
  if (!isBearer(key)) url.searchParams.set("api_key", key);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  const headers = isBearer(key) ? { Authorization: `Bearer ${key}` } : {};
  const r = await fetch(url, { headers });
  if (!r.ok) throw new Error(`TMDB ${r.status} ${pathPart}`);
  return r.json();
}

export async function lookupShow({ query, mediaType, tmdbKey }) {
  const data = await tmdb(`/search/${mediaType}`, { query }, tmdbKey);
  const hits = (data.results || []).slice(0, 8).map((r) => ({
    tmdbID: r.id,
    name: r.name || r.title,
    year: (r.first_air_date || r.release_date || "").slice(0, 4),
    overview: (r.overview || "").slice(0, 200),
  }));

  const manifest = await loadManifest();
  for (const h of hits) {
    const entry = manifest.items[`${mediaType}:${h.tmdbID}`];
    if (entry) {
      h.claim = { channels: entry.channels, source: entry.source };
    }
  }

  // Primary "the answer" — first hit's claim status
  const primary = hits[0];
  return {
    query,
    mediaType,
    hits,
    claim: primary?.claim
      ? { ...primary.claim, name: primary.name, tmdbID: primary.tmdbID }
      : null,
  };
}

// Given a TMDB ID, fetch its recs+similar from each channel's exemplars to
// explain WHY it's connected (or not) to a channel.
export async function channelLookupConnections({ tmdbID, mediaType, tmdbKey }) {
  const exemplars = await loadExemplars();
  const out = [];

  for (const ch of exemplars.channels) {
    if (ch.mediaType !== mediaType) continue;
    const connections = [];
    for (const ex of ch.exemplars) {
      const search = await tmdb(`/search/${mediaType}`, { query: ex }, tmdbKey).catch(() => null);
      const found = search?.results?.[0];
      if (!found) continue;
      const base = mediaType === "tv" ? `/tv/${found.id}` : `/movie/${found.id}`;
      const [recs, sims] = await Promise.all([
        tmdb(`${base}/recommendations`, {}, tmdbKey).catch(() => ({ results: [] })),
        tmdb(`${base}/similar`, {}, tmdbKey).catch(() => ({ results: [] })),
      ]);
      const inRec = (recs.results || []).some((r) => r.id === tmdbID);
      const inSim = (sims.results || []).some((r) => r.id === tmdbID);
      if (inRec || inSim) {
        connections.push({
          exemplar: ex,
          exemplarTmdbID: found.id,
          tags: [inRec && "rec", inSim && "sim"].filter(Boolean),
        });
      }
    }
    out.push({ channelID: ch.id, channelName: ch.name, connectionCount: connections.length, connections });
  }
  return { tmdbID, mediaType, results: out };
}
