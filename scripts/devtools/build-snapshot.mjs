#!/usr/bin/env node
// Build a devtools snapshot from Plex without the tvOS app.
// Credentials are read from a .env file (set once, never committed).
//
// Usage:
//   npm run snapshot          → build and save snapshot.json
//   npm run start:full        → build snapshot then start server

import { writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { plexConfigured, listSections, listMovieItems, listEpisodeItems, normalizeItem } from "./lib/plex.mjs";
import { loadChannels, poolFor } from "./lib/channels.mjs";
import { buildScheduleRange } from "./lib/schedule.mjs";
import { fetchMovieKeywords, fetchShowKeywords, flushCache, tmdbConfigured } from "./lib/tmdb.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const STORE_PATH = join(__dirname, "snapshot.json");

if (!plexConfigured) {
  console.error("\nError: PLEX_URL and PLEX_TOKEN are required.");
  console.error("Create scripts/devtools/.env with:");
  console.error("  PLEX_URL=https://your-plex-server:32400");
  console.error("  PLEX_TOKEN=your_token_here\n");
  process.exit(1);
}

const BACK_DAYS    = 3;
const FORWARD_DAYS = 14;
const nowSec  = Math.floor(Date.now() / 1000);
const fromSec = nowSec - BACK_DAYS    * 86400;
const toSec   = nowSec + FORWARD_DAYS * 86400;

console.log("\nBuilding Nostalgex snapshot from Plex...\n");

// 1. Fetch all library items
console.log("Fetching library sections...");
const sections = await listSections();
const allItems = [];
for (const s of sections) {
  process.stdout.write(`  ${s.title} (${s.type})...`);
  const raw = s.type === "movie"
    ? await listMovieItems(s.key)
    : await listEpisodeItems(s.key);
  const normalized = raw.map((r) => normalizeItem(r, s.type, s.title));
  allItems.push(...normalized);
  process.stdout.write(` ${normalized.length}\n`);
}
console.log(`\nTotal items: ${allItems.length}`);

// 2. Enrich movies with TMDB keywords
if (tmdbConfigured) {
  const movies = allItems.filter((it) => it.librarySource === "movie");
  console.log(`\nFetching TMDB keywords for ${movies.length} movies...`);
  let done = 0;
  for (const item of movies) {
    item.tmdbKeywords = await fetchMovieKeywords(item);
    done++;
    if (done % 100 === 0) {
      process.stdout.write(`  ${done}/${movies.length}\n`);
      await flushCache();
    }
  }
  await flushCache();
  console.log(`  Done — ${movies.length} movies enriched`);

  // 3. Enrich episodes with their SHOW's TMDB keywords (one fetch per show)
  const episodes = allItems.filter((it) => it.type === "episode" && it.tmdbID);
  const showIDs = [...new Set(episodes.map((it) => it.tmdbID))];
  console.log(`\nFetching TMDB keywords for ${showIDs.length} shows (${episodes.length} episodes)...`);
  const kwByShow = new Map();
  let doneShows = 0;
  for (const id of showIDs) {
    kwByShow.set(id, await fetchShowKeywords(id));
    doneShows++;
    if (doneShows % 50 === 0) { process.stdout.write(`  ${doneShows}/${showIDs.length}\n`); await flushCache(); }
  }
  for (const it of episodes) it.tmdbKeywords = kwByShow.get(it.tmdbID) || [];
  await flushCache();
  console.log(`  Done — ${showIDs.length} shows enriched\n`);
} else {
  console.log("\nTMDB_API_KEY not set — skipping keyword enrichment");
}

// 4. Build item lookup keyed by ratingKey (snapshot.items shape)
const items = {};
for (const item of allItems) {
  items[item.ratingKey] = item;
}

// 5. Run channel filter + schedule for every channel
console.log("\nBuilding channel pools and schedules...");
const cfg = await loadChannels();
const snapshotChannels = [];

for (const channel of cfg.channels) {
  process.stdout.write(`  [${channel.number}] ${channel.name}...`);
  const { items: pool } = await poolFor(channel, allItems);
  const schedule = buildScheduleRange(channel, pool, fromSec, toSec);
  process.stdout.write(` ${pool.length} items, ${schedule.length} slots\n`);

  snapshotChannels.push({
    id:       channel.id,
    number:   channel.number,
    name:     channel.name,
    category: channel.category || null,
    poolKeys: pool.map((it) => it.ratingKey),
    schedule: schedule.map((e) => ({
      ratingKey: e.item.ratingKey,
      startSec:  e.startSec,
      endSec:    e.endSec,
    })),
  });
}

// 6. Assemble and save
const snapshot = {
  version:       1,
  generatedAt:   nowSec,
  deviceName:    "DevTools",
  appVersion:    "devtools",
  totalChannels: snapshotChannels.length,
  totalItems:    allItems.length,
  fromSec,
  toSec,
  channels: snapshotChannels,
  items,
};

const savedAt = nowSec;
await writeFile(STORE_PATH, JSON.stringify({ snapshot, savedAt }));

console.log(`\nSnapshot saved → snapshot.json`);
console.log(`  ${snapshotChannels.length} channels  ·  ${allItems.length} items`);
console.log(`  Schedule: ${BACK_DAYS}d back, ${FORWARD_DAYS}d forward\n`);
