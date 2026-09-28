// Snapshot store. Holds an in-memory copy of the latest DiagnosticSnapshot
// uploaded by the Apple TV app, and persists it to disk so it survives server
// restarts. Schema mirrors Services/SnapshotExporter.swift.

import { readFile, writeFile, mkdir, stat } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const STORE_PATH = join(__dirname, "..", "snapshot.json");

let current = null; // parsed snapshot object
let savedAt = 0;    // server-side receive time (unix sec)

export function getSnapshot() {
  return current ? { snapshot: current, savedAt } : null;
}

export function snapshotSummary() {
  if (!current) return null;
  return {
    generatedAt: current.generatedAt,
    savedAt,
    deviceName: current.deviceName,
    appVersion: current.appVersion || null,
    totalChannels: current.totalChannels,
    totalItems: current.totalItems,
    fromSec: current.fromSec,
    toSec: current.toSec,
  };
}

export async function loadFromDisk() {
  try {
    const buf = await readFile(STORE_PATH, "utf8");
    const data = JSON.parse(buf);
    current = data.snapshot;
    savedAt = data.savedAt;
    if (current) {
      console.log(`[devtools] restored snapshot from disk: ${current.totalChannels} channels, ${current.totalItems} items, generated ${new Date(current.generatedAt * 1000).toISOString()}`);
    }
  } catch {
    // No snapshot yet — fine
  }
}

export async function storeSnapshot(payload) {
  validateSnapshot(payload);
  current = payload;
  savedAt = Math.floor(Date.now() / 1000);
  try {
    await mkdir(dirname(STORE_PATH), { recursive: true });
    await writeFile(STORE_PATH, JSON.stringify({ snapshot: current, savedAt }));
  } catch (e) {
    console.warn(`[devtools] failed to persist snapshot to disk: ${e.message}`);
  }
}

export function clearSnapshot() {
  current = null;
  savedAt = 0;
  // Don't await — best-effort, and we don't have an unlink helper without
  // bringing in node:fs/promises.rm. Just overwrite with an empty marker.
  writeFile(STORE_PATH, JSON.stringify({ snapshot: null, savedAt: 0 })).catch(() => {});
}

function validateSnapshot(s) {
  if (!s || typeof s !== "object") throw new Error("snapshot is not an object");
  if (s.version !== 1) throw new Error(`unsupported snapshot version: ${s.version}`);
  if (!Array.isArray(s.channels)) throw new Error("snapshot.channels missing");
  if (!s.items || typeof s.items !== "object") throw new Error("snapshot.items missing");
}

// Build the same rows shape that the existing /api/schedule endpoint produces,
// but sourced from the snapshot instead of recomputing via JS.
export function scheduleRowsFromSnapshot({ channelIdFilter = null, queryStr = "" } = {}) {
  if (!current) return null;
  const q = queryStr.trim().toLowerCase();
  const channels = channelIdFilter
    ? current.channels.filter((c) => String(c.id) === String(channelIdFilter))
    : current.channels;

  const rows = [];
  for (const ch of channels) {
    for (const e of ch.schedule || []) {
      const item = current.items[e.ratingKey];
      if (!item) continue;
      const display = item.displayTitle || item.title;
      if (q && !display.toLowerCase().includes(q)) continue;
      rows.push({
        channelId: ch.id,
        channelNumber: ch.number,
        channelName: ch.name,
        startSec: e.startSec,
        endSec: e.endSec,
        title: display,
        year: item.year,
        ratingKey: e.ratingKey,
      });
    }
  }
  rows.sort((a, b) => a.startSec - b.startSec);
  return rows;
}

// Build the pool detail payload from the snapshot for a single channel.
// Matches the live /api/channel/:id/pool response shape.
export function poolPayloadFromSnapshot(channelId) {
  if (!current) return null;
  const ch = current.channels.find((c) => c.id === Number(channelId));
  if (!ch) return null;
  const pool = ch.poolKeys.map((k) => current.items[k]).filter(Boolean);

  // Breakdowns (same as the live endpoint)
  const decades = {};
  const types = {};
  const ratings = {};
  const genreCounts = {};
  let viewedCount = 0;
  let totalRuntimeMin = 0;
  for (const it of pool) {
    const dec = it.year ? `${Math.floor(it.year / 10) * 10}s` : "unknown";
    decades[dec] = (decades[dec] || 0) + 1;
    types[it.type] = (types[it.type] || 0) + 1;
    if (it.contentRating) ratings[it.contentRating] = (ratings[it.contentRating] || 0) + 1;
    for (const g of it.genres || []) genreCounts[g] = (genreCounts[g] || 0) + 1;
    if (it.viewCount > 0) viewedCount++;
    totalRuntimeMin += it.duration || 0;
  }

  return {
    channel: { id: ch.id, number: ch.number, name: ch.name, category: ch.category || null },
    stats: {
      poolSize: pool.length,
      librarySize: Object.keys(current.items).length,
      viewedCount,
      totalRuntimeMin,
      loopHours: totalRuntimeMin / 60,
      decades,
      types,
      ratings,
      topGenres: Object.entries(genreCounts).sort((a, b) => b[1] - a[1]).slice(0, 10),
    },
    items: pool.slice(0, 2000).map((it) => ({
      ratingKey: it.title ? null : null, // (we don't carry ratingKey in items; UI doesn't need it)
      title: it.displayTitle || it.title,
      type: it.type,
      year: it.year,
      duration: it.duration,
      viewCount: it.viewCount,
      contentRating: it.contentRating,
      genres: it.genres,
      studio: it.studio,
    })),
    truncated: pool.length > 2000,
  };
}

export function channelsFromSnapshot() {
  if (!current) return null;
  return current.channels.map((c) => ({
    id: c.id,
    number: c.number,
    name: c.name,
    category: c.category || null,
    poolSize: c.poolKeys.length,
  }));
}
