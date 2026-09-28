#!/usr/bin/env node
// Nostalgex dev tools — local HTTP server that powers the web UIs for the
// schedule explorer and the library audit. Zero framework, no build step.
//
// Usage:
//   PLEX_URL=https://your-plex:32400 PLEX_TOKEN=xxxx node server.mjs
//   (then open http://localhost:3030)
//
// Optional:
//   PORT=3030

import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { extname, join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import { plexConfigured, plexHost, listSections, listMovieItems, listEpisodeItems, normalizeItem } from "./lib/plex.mjs";
import { loadChannels, poolFor, unsupportedRulesFor, partialRulesFor } from "./lib/channels.mjs";
import { buildScheduleRange } from "./lib/schedule.mjs";
import { runAudit } from "./lib/audit.mjs";
import { loadFromDisk as loadSnapshotFromDisk, storeSnapshot, clearSnapshot, snapshotSummary, getSnapshot, scheduleRowsFromSnapshot, poolPayloadFromSnapshot, channelsFromSnapshot } from "./lib/snapshot.mjs";
import { loadManifest, loadExemplars, manifestSummary, claimsForChannel, conflicts, lookupShow, channelLookupConnections } from "./lib/memberships.mjs";
import { coverageFromSnapshot } from "./lib/coverage.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = join(__dirname, "public");
const PORT = Number(process.env.PORT || 3030);

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".mjs": "application/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
};

// ---- Caches --------------------------------------------------------------
// Plex item list (per-section) is heavy. Cache for the lifetime of the server
// process. Set REFRESH_ITEMS=1 to force a re-fetch on next request.
let itemsCache = null;
let auditJob = null; // { id, status, progress, result, error }

async function loadAllItems({ force = false } = {}) {
  if (itemsCache && !force) return itemsCache;
  console.log("[devtools] fetching Plex library...");
  const sections = await listSections();
  const items = [];
  for (const s of sections) {
    process.stdout.write(`[devtools]   ${s.title} (${s.type})...`);
    const raw = s.type === "movie" ? await listMovieItems(s.key) : await listEpisodeItems(s.key);
    const normalized = raw.map((r) => normalizeItem(r, s.type, s.title));
    items.push(...normalized);
    process.stdout.write(` ${normalized.length}\n`);
  }
  itemsCache = items;
  console.log(`[devtools] cached ${items.length} items across ${sections.length} sections`);
  return items;
}

// ---- HTTP helpers --------------------------------------------------------
function sendJSON(res, status, payload) {
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
  res.end(JSON.stringify(payload));
}

function sendError(res, status, message) {
  sendJSON(res, status, { error: message });
}

async function serveStatic(req, res) {
  const url = new URL(req.url, "http://localhost");
  let path = url.pathname === "/" ? "/index.html" : url.pathname;
  // Block traversal
  if (path.includes("..")) return sendError(res, 400, "bad path");
  const filePath = join(PUBLIC_DIR, path);
  try {
    const s = await stat(filePath);
    if (!s.isFile()) throw new Error("not a file");
    const body = await readFile(filePath);
    const ext = extname(filePath).toLowerCase();
    res.writeHead(200, { "Content-Type": MIME[ext] || "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404, { "Content-Type": "text/plain" });
    res.end("not found");
  }
}

// ---- Routes --------------------------------------------------------------
async function routeAPI(req, res, url) {
  const path = url.pathname;

  if (path === "/api/health") {
    return sendJSON(res, 200, {
      ok: true,
      plexConfigured,
      plexHost: plexHost || null,
      tmdbConfigured: Boolean(process.env.TMDB_API_KEY),
      itemsCached: itemsCache?.length || 0,
      snapshot: snapshotSummary(),
    });
  }

  // ---- Memberships ------------------------------------------------------
  // All read straight off channels-memberships.json + exemplars.json.
  // No Plex, no Snapshot required. TMDB only needed for live lookups.
  if (path === "/api/memberships/summary" && req.method === "GET") {
    const cfg = await loadChannels().catch(() => ({ channels: [] }));
    const channelNames = new Map(cfg.channels.map((c) => [c.id, { name: c.name, number: c.number }]));
    return sendJSON(res, 200, await manifestSummary(channelNames));
  }
  const claimsMatch = path.match(/^\/api\/memberships\/channel\/(\d+)$/);
  if (claimsMatch && req.method === "GET") {
    return sendJSON(res, 200, await claimsForChannel(Number(claimsMatch[1])));
  }
  if (path === "/api/memberships/conflicts" && req.method === "GET") {
    const cfg = await loadChannels().catch(() => ({ channels: [] }));
    const channelNames = new Map(cfg.channels.map((c) => [c.id, c.name]));
    return sendJSON(res, 200, await conflicts(channelNames));
  }
  if (path === "/api/memberships/lookup" && req.method === "GET") {
    const q = url.searchParams.get("q") || "";
    const mediaType = url.searchParams.get("mediaType") === "movie" ? "movie" : "tv";
    if (!q) return sendError(res, 400, "missing q");
    if (!process.env.TMDB_API_KEY) {
      return sendError(res, 500, "TMDB_API_KEY env var not set on devtools server");
    }
    try {
      const result = await lookupShow({ query: q, mediaType, tmdbKey: process.env.TMDB_API_KEY });
      const cfg = await loadChannels().catch(() => ({ channels: [] }));
      const channelNames = new Map(cfg.channels.map((c) => [c.id, c.name]));
      // Resolve claim → channel name
      if (result.claim) {
        result.claim.channelNames = result.claim.channels.map((cid) => channelNames.get(cid) || String(cid));
      }
      return sendJSON(res, 200, result);
    } catch (e) {
      return sendError(res, 500, e.message);
    }
  }
  // Reverse-graph lookup: which exemplars (per channel) list a given TMDB ID
  // as related? Useful for explaining why an item got claimed.
  if (path === "/api/memberships/connections" && req.method === "GET") {
    const id = url.searchParams.get("id");
    const mediaType = url.searchParams.get("mediaType") === "movie" ? "movie" : "tv";
    if (!id) return sendError(res, 400, "missing id");
    if (!process.env.TMDB_API_KEY) {
      return sendError(res, 500, "TMDB_API_KEY env var not set on devtools server");
    }
    try {
      const result = await channelLookupConnections({ tmdbID: Number(id), mediaType, tmdbKey: process.env.TMDB_API_KEY });
      return sendJSON(res, 200, result);
    } catch (e) {
      return sendError(res, 500, e.message);
    }
  }

  // ---- Snapshot endpoints (no Plex required) -----------------------------
  if (path === "/api/snapshot/upload" && req.method === "POST") {
    let body = "";
    const maxBytes = 50 * 1024 * 1024; // 50 MB hard cap
    req.setEncoding("utf8");
    for await (const chunk of req) {
      body += chunk;
      if (body.length > maxBytes) return sendError(res, 413, "snapshot too large (>50 MB)");
    }
    try {
      const payload = JSON.parse(body);
      await storeSnapshot(payload);
      const sum = snapshotSummary();
      console.log(`[devtools] snapshot received: ${sum.totalChannels} channels, ${sum.totalItems} items from ${sum.deviceName}`);
      return sendJSON(res, 200, { ok: true, summary: sum });
    } catch (e) {
      return sendError(res, 400, `bad snapshot: ${e.message}`);
    }
  }
  if (path === "/api/snapshot" && req.method === "GET") {
    const sum = snapshotSummary();
    if (!sum) return sendJSON(res, 200, { snapshot: null });
    return sendJSON(res, 200, { snapshot: sum });
  }
  if (path === "/api/snapshot/clear" && req.method === "POST") {
    clearSnapshot();
    return sendJSON(res, 200, { ok: true });
  }

  // ---- Snapshot-served endpoints (preferred when snapshot present) -------
  const snap = snapshotSummary();
  if (snap) {
    // Coverage: every item → which channels pool it. Snapshot-only by design;
    // the whole point is to inspect the pools the filter actually produced.
    if (path === "/api/coverage" && req.method === "GET") {
      const cfg = await loadChannels().catch(() => ({ channels: [] }));
      const manifest = await loadManifest();
      return sendJSON(res, 200, { source: "snapshot", ...coverageFromSnapshot(getSnapshot().snapshot, manifest, cfg.channels) });
    }
    if (path === "/api/channels" && req.method === "GET") {
      const fromSnap = channelsFromSnapshot();
      const cfg = await loadChannels().catch(() => ({ channels: [] }));
      const ruleInfoById = new Map(cfg.channels.map((c) => [c.id, {
        unsupportedRules: unsupportedRulesFor(c),
        partialRules: partialRulesFor(c),
      }]));
      return sendJSON(res, 200, {
        source: "snapshot",
        channels: fromSnap.map((c) => ({
          ...c,
          unsupportedRules: ruleInfoById.get(c.id)?.unsupportedRules || [],
          partialRules: ruleInfoById.get(c.id)?.partialRules || [],
        })).sort((a, b) => (a.number || 0) - (b.number || 0)),
      });
    }
    if (path === "/api/schedule" && req.method === "GET") {
      const rows = scheduleRowsFromSnapshot({
        channelIdFilter: url.searchParams.get("channelId"),
        queryStr: url.searchParams.get("q") || "",
      }) || [];
      return sendJSON(res, 200, {
        source: "snapshot",
        from: snap.fromSec,
        to: snap.toSec,
        nowSec: Math.floor(Date.now() / 1000),
        total: rows.length,
        rows: rows.slice(0, 20000),
        truncated: rows.length > 20000,
      });
    }
    const pmSnap = path.match(/^\/api\/channel\/(\d+)\/pool$/);
    if (pmSnap && req.method === "GET") {
      const payload = poolPayloadFromSnapshot(pmSnap[1]);
      if (!payload) return sendError(res, 404, "channel not in snapshot");
      const cfg = await loadChannels().catch(() => ({ channels: [] }));
      const channel = cfg.channels.find((c) => c.id === Number(pmSnap[1]));
      return sendJSON(res, 200, {
        source: "snapshot",
        ...payload,
        rules: channel?.rules || {},
        unsupportedRules: channel ? unsupportedRulesFor(channel) : [],
        partialRules: channel ? partialRulesFor(channel) : [],
      });
    }
    // Other endpoints fall through to the live (Plex-backed) versions below.
  }

  if (path === "/api/coverage") {
    return sendError(res, 409, "No snapshot loaded. Coverage reads the snapshot's per-channel pools, so build one first: npm run snapshot (needs PLEX_URL and PLEX_TOKEN in .env), then restart the devtools.");
  }

  // GET /api/channels — channel list with rule support info (no Plex or snapshot needed)
  if (path === "/api/channels" && req.method === "GET") {
    const cfg = await loadChannels();
    return sendJSON(res, 200, {
      source: "config",
      channels: cfg.channels.map((c) => ({
        id: c.id,
        number: c.number,
        name: c.name,
        category: c.category || null,
        unsupportedRules: unsupportedRulesFor(c),
        partialRules: partialRulesFor(c),
      })).sort((a, b) => (a.number || 0) - (b.number || 0)),
    });
  }

  if (!plexConfigured) {
    return sendError(res, 500, "PLEX_URL and PLEX_TOKEN env vars are required for live mode. Upload a snapshot from the app to browse schedule and pool data.");
  }

  // GET /api/schedule?days=7&channelId=optional — schedule range
  if (path === "/api/schedule" && req.method === "GET") {
    const back = Number(url.searchParams.get("back") || 7);
    const forward = Number(url.searchParams.get("forward") || 7);
    const channelIdFilter = url.searchParams.get("channelId");
    const queryStr = (url.searchParams.get("q") || "").toLowerCase();
    const items = await loadAllItems();
    const cfg = await loadChannels();
    const nowSec = Math.floor(Date.now() / 1000);
    const fromSec = nowSec - back * 86400;
    const toSec = nowSec + forward * 86400;

    const channels = channelIdFilter
      ? cfg.channels.filter((c) => String(c.id) === String(channelIdFilter))
      : cfg.channels;

    const rows = [];
    for (const channel of channels) {
      const { items: pool } = await poolFor(channel, items);
      if (!pool.length) continue;
      const entries = buildScheduleRange(channel, pool, fromSec, toSec);
      for (const e of entries) {
        // Search matches against the display title (Show — Episode for episodes,
        // movie title for movies) — that's what the user sees and expects to search.
        const searchable = (e.item.displayTitle || e.item.title).toLowerCase();
        if (queryStr && !searchable.includes(queryStr)) continue;
        rows.push({
          channelId: channel.id,
          channelNumber: channel.number,
          channelName: channel.name,
          startSec: e.startSec,
          endSec: e.endSec,
          title: e.item.displayTitle || e.item.title,
          year: e.item.year,
          ratingKey: e.item.ratingKey,
        });
      }
    }
    rows.sort((a, b) => a.startSec - b.startSec);
    return sendJSON(res, 200, {
      from: fromSec,
      to: toSec,
      nowSec,
      total: rows.length,
      rows: rows.slice(0, 10000),
      truncated: rows.length > 10000,
    });
  }

  // GET /api/channel/:id/pool — what titles are eligible for this channel,
  // plus the rules that produced the pool and a quick breakdown.
  const poolMatch = path.match(/^\/api\/channel\/(\d+)\/pool$/);
  if (poolMatch && req.method === "GET") {
    const channelId = Number(poolMatch[1]);
    const items = await loadAllItems();
    const cfg = await loadChannels();
    const channel = cfg.channels.find((c) => c.id === channelId);
    if (!channel) return sendError(res, 404, "channel not found");
    const { items: pool, shows, requiresAnimation } = await poolFor(channel, items);

    // Decade + type breakdowns help spot misconfigured rules at a glance.
    const decadeCounts = {};
    const typeCounts = {};
    const genreCounts = {};
    const ratingCounts = {};
    const viaCounts = { rules: 0, manifest: 0, editorial: 0 };
    let viewedCount = 0;
    let totalRuntimeMin = 0;
    let suspectCount = 0;
    for (const it of pool) {
      const decade = it.year ? `${Math.floor(it.year / 10) * 10}s` : "unknown";
      decadeCounts[decade] = (decadeCounts[decade] || 0) + 1;
      typeCounts[it.type] = (typeCounts[it.type] || 0) + 1;
      if (it.contentRating) ratingCounts[it.contentRating] = (ratingCounts[it.contentRating] || 0) + 1;
      for (const g of it.genres || []) genreCounts[g] = (genreCounts[g] || 0) + 1;
      if (it.viewCount > 0) viewedCount++;
      totalRuntimeMin += it.duration || 0;
      if (it.poolVia && viaCounts[it.poolVia] != null) viaCounts[it.poolVia]++;
      if (it.suspectNonAnimation) suspectCount++;
    }

    const suspectShows = shows.filter((s) => s.suspectNonAnimation);

    return sendJSON(res, 200, {
      channel: { id: channel.id, number: channel.number, name: channel.name, category: channel.category || null },
      rules: channel.rules || {},
      unsupportedRules: unsupportedRulesFor(channel),
      partialRules: partialRulesFor(channel),
      requiresAnimation,
      stats: {
        poolSize: pool.length,
        showCount: shows.length,
        librarySize: items.length,
        viewedCount,
        totalRuntimeMin,
        loopHours: totalRuntimeMin / 60,
        decades: decadeCounts,
        types: typeCounts,
        ratings: ratingCounts,
        topGenres: Object.entries(genreCounts).sort((a, b) => b[1] - a[1]).slice(0, 10),
        via: viaCounts,
        suspectEpisodeCount: suspectCount,
        suspectShowCount: suspectShows.length,
      },
      suspectShows,
      shows: shows.slice(0, 500),
      items: pool.slice(0, 2000).map((it) => ({
        ratingKey: it.ratingKey,
        title: it.displayTitle || it.title,
        showTitle: it.title,
        type: it.type,
        year: it.year,
        duration: it.duration,
        viewCount: it.viewCount,
        contentRating: it.contentRating,
        genres: it.genres,
        studio: it.studio,
        tmdbID: it.tmdbID,
        poolVia: it.poolVia,
        hasAnimationGenre: it.hasAnimationGenre,
        suspectNonAnimation: it.suspectNonAnimation,
      })),
      truncated: pool.length > 2000,
    });
  }

  // POST /api/items/refresh — force re-fetch Plex items
  if (path === "/api/items/refresh" && req.method === "POST") {
    itemsCache = null;
    await loadAllItems();
    return sendJSON(res, 200, { ok: true, count: itemsCache.length });
  }

  // POST /api/audit/start — kick off an audit job
  if (path === "/api/audit/start" && req.method === "POST") {
    if (auditJob && auditJob.status === "running") {
      return sendJSON(res, 200, { id: auditJob.id, status: auditJob.status });
    }
    const id = String(Date.now());
    auditJob = { id, status: "running", progress: { phase: "starting" }, result: null, error: null };
    runAudit({
      onProgress: (p) => { if (auditJob?.id === id) auditJob.progress = p; },
    })
      .then((result) => { if (auditJob?.id === id) { auditJob.status = "done"; auditJob.result = result; } })
      .catch((e) => { if (auditJob?.id === id) { auditJob.status = "error"; auditJob.error = e.message; } });
    return sendJSON(res, 200, { id, status: "running" });
  }

  // GET /api/audit/status — poll job status
  if (path === "/api/audit/status" && req.method === "GET") {
    if (!auditJob) return sendJSON(res, 200, { status: "idle" });
    return sendJSON(res, 200, {
      id: auditJob.id,
      status: auditJob.status,
      progress: auditJob.progress,
      error: auditJob.error,
      summary: auditJob.result
        ? {
            totalScanned: auditJob.result.totalScanned,
            totalItems: auditJob.result.totalItems,
            itemErrors: auditJob.result.itemErrors,
            sectionErrors: auditJob.result.sectionErrors,
            findings: auditJob.result.findings.length,
            groupCount: auditJob.result.groups.length,
          }
        : null,
    });
  }

  // GET /api/audit/result — full result of last run
  if (path === "/api/audit/result" && req.method === "GET") {
    if (!auditJob || auditJob.status !== "done") return sendError(res, 404, "no completed audit");
    return sendJSON(res, 200, auditJob.result);
  }

  return sendError(res, 404, "unknown endpoint");
}

// ---- Boot ----------------------------------------------------------------
const server = createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  try {
    if (url.pathname.startsWith("/api/")) {
      await routeAPI(req, res, url);
    } else {
      await serveStatic(req, res);
    }
  } catch (e) {
    console.error("[devtools] error:", e);
    sendError(res, 500, e.message);
  }
});

await loadSnapshotFromDisk();
server.listen(PORT, () => {
  const sum = snapshotSummary();
  console.log("");
  console.log(`  Nostalgex devtools running:  http://localhost:${PORT}`);
  console.log(`  Plex:      ${plexConfigured ? plexHost : "not connected (channels browseable; schedule/pool need snapshot or Plex)"}`);
  console.log(`  Snapshot:  ${sum ? `${sum.totalChannels} channels from ${sum.deviceName} (saved ${new Date(sum.savedAt * 1000).toLocaleString()})` : "none"}`);
  console.log("");
});
