#!/usr/bin/env node
// One-off discovery: enumerate every TMDB title tagged with "stand-up comedy"
// keyword and claim it for STAND-UP (CH 58) with exclusive:58 in the manifest.
// Mirrors the gate-based runtime contract: the lock blocks these titles from
// every other channel via the manifest's exclusive flag.
//
// Usage:
//   TMDB_API_KEY=xxx node scripts/channel-keyword-tuner/discover-standup.mjs

import fs from "node:fs/promises";
import fsSync from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const MANIFEST_PATH = path.join(__dirname, "..", "..", "channels-memberships.json");

// Auto-load plex-90/.env so the script just works without `source .env` first.
(function loadDotEnv() {
  const envPath = path.join(__dirname, "..", "..", ".env");
  if (!fsSync.existsSync(envPath)) return;
  for (const line of fsSync.readFileSync(envPath, "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)\s*$/);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^['"]|['"]$/g, "");
  }
})();

const TMDB = "https://api.themoviedb.org/3";
const KEY = process.env.TMDB_API_KEY;
const STANDUP_KEYWORD_ID = 9716;
const STANDUP_CHANNEL_ID = 58;

if (!KEY) {
  console.error("Missing TMDB_API_KEY");
  process.exit(1);
}

const isBearer = KEY.startsWith("eyJ");

async function tmdb(pathPart, params = {}) {
  const url = new URL(TMDB + pathPart);
  if (!isBearer) url.searchParams.set("api_key", KEY);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  const headers = isBearer ? { Authorization: `Bearer ${KEY}` } : {};
  const r = await fetch(url, { headers });
  if (!r.ok) throw new Error(`TMDB ${r.status} ${pathPart}`);
  return r.json();
}

async function discoverAll(mediaType) {
  const out = [];
  let page = 1;
  while (true) {
    const data = await tmdb(`/discover/${mediaType}`, {
      with_keywords: STANDUP_KEYWORD_ID,
      page,
      sort_by: "popularity.desc",
    });
    for (const r of data.results || []) {
      out.push({
        id: r.id,
        name: r.title || r.name,
        year: (r.release_date || r.first_air_date || "").slice(0, 4),
        mediaType,
      });
    }
    const totalPages = Math.min(data.total_pages || 1, 500); // TMDB caps at 500
    console.error(`  ${mediaType} page ${page}/${totalPages} — ${data.results?.length || 0} hits`);
    if (page >= totalPages) break;
    page++;
  }
  return out;
}

async function main() {
  console.error("Discovering stand-up specials from TMDB…");
  const [movies, tv] = await Promise.all([
    discoverAll("movie"),
    discoverAll("tv"),
  ]);
  const total = movies.length + tv.length;
  console.error(`\nFound ${movies.length} movies + ${tv.length} tv = ${total} total stand-up specials`);

  // Merge into existing manifest
  const raw = await fs.readFile(MANIFEST_PATH, "utf8");
  const m = JSON.parse(raw);
  m.items = m.items || {};

  let added = 0, updated = 0, alreadyLocked = 0;
  for (const item of [...movies, ...tv]) {
    const key = `${item.mediaType}:${item.id}`;
    const entry = m.items[key];
    if (entry) {
      // Already in manifest — make sure it's locked to STAND-UP only
      if (entry.exclusive === STANDUP_CHANNEL_ID) { alreadyLocked++; continue; }
      entry.channels = [STANDUP_CHANNEL_ID];
      entry.exclusive = STANDUP_CHANNEL_ID;
      if (!entry.source?.includes("tmdb-keyword")) {
        entry.source = `tmdb-keyword:stand-up comedy (was: ${entry.source || "?"})`;
      }
      updated++;
    } else {
      m.items[key] = {
        channels: [STANDUP_CHANNEL_ID],
        source: "tmdb-keyword:stand-up comedy",
        name: item.name,
        mediaType: item.mediaType,
        exclusive: STANDUP_CHANNEL_ID,
      };
      added++;
    }
  }

  m.version = (m.version || 0) + 1;
  m.generated = new Date().toISOString();
  await fs.writeFile(MANIFEST_PATH, JSON.stringify(m, null, 2));

  console.error(`\nManifest updated:`);
  console.error(`  added: ${added}`);
  console.error(`  updated/relocked: ${updated}`);
  console.error(`  already locked: ${alreadyLocked}`);
  console.error(`  total locked to STAND-UP now: ${added + updated + alreadyLocked}`);
  console.error(`  new manifest version: ${m.version}`);
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
