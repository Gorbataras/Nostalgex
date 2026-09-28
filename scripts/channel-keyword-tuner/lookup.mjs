#!/usr/bin/env node
// Lookup helper — check what channels claim a given show/movie, and what
// exemplars it's adjacent to in TMDB's recommendation graph.
//
// Usage:
//   TMDB_API_KEY=xxx node scripts/channel-keyword-tuner/lookup.mjs "Gilmore Girls"
//   TMDB_API_KEY=xxx node scripts/channel-keyword-tuner/lookup.mjs "Ballers" --movie
//   TMDB_API_KEY=xxx node scripts/channel-keyword-tuner/lookup.mjs --tmdb-id 1396 --tv

import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TMDB = "https://api.themoviedb.org/3";
const KEY = process.env.TMDB_API_KEY;

if (!KEY) {
  console.error("Missing TMDB_API_KEY env var");
  process.exit(1);
}

const isBearerToken = KEY.startsWith("eyJ");

async function tmdb(pathPart, params = {}) {
  const url = new URL(TMDB + pathPart);
  if (!isBearerToken) url.searchParams.set("api_key", KEY);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  const headers = isBearerToken ? { Authorization: `Bearer ${KEY}` } : {};
  const r = await fetch(url, { headers });
  if (!r.ok) throw new Error(`TMDB ${r.status} ${pathPart}`);
  return r.json();
}

const args = process.argv.slice(2);
const isMovie = args.includes("--movie");
const isTv = args.includes("--tv") || !isMovie; // default to TV
const mediaType = isMovie ? "movie" : "tv";
const tmdbIDArg = args.includes("--tmdb-id") ? args[args.indexOf("--tmdb-id") + 1] : null;
const query = args.find(a => !a.startsWith("--") && a !== tmdbIDArg);

if (!query && !tmdbIDArg) {
  console.error('Usage: lookup.mjs "<title>" [--movie|--tv]');
  console.error('       lookup.mjs --tmdb-id <id> [--movie|--tv]');
  process.exit(1);
}

async function loadManifest() {
  const p = path.join(__dirname, "..", "..", "channels-memberships.json");
  return JSON.parse(await fs.readFile(p, "utf8"));
}

async function loadExemplars() {
  const p = path.join(__dirname, "exemplars.json");
  return JSON.parse(await fs.readFile(p, "utf8"));
}

async function loadChannelNames() {
  const p = path.join(__dirname, "..", "..", "channels.json");
  const config = JSON.parse(await fs.readFile(p, "utf8"));
  const map = {};
  for (const ch of config.channels) map[ch.id] = ch.name;
  return map;
}

async function searchTitle(title) {
  const data = await tmdb(`/search/${mediaType}`, { query: title });
  return (data.results || []).slice(0, 5).map(r => ({
    id: r.id,
    name: r.name || r.title,
    year: (r.first_air_date || r.release_date || "").slice(0, 4),
    overview: (r.overview || "").slice(0, 120),
  }));
}

async function fetchRelated(id) {
  const base = mediaType === "tv" ? `/tv/${id}` : `/movie/${id}`;
  const [recs, sims] = await Promise.all([
    tmdb(`${base}/recommendations`).catch(() => ({ results: [] })),
    tmdb(`${base}/similar`).catch(() => ({ results: [] })),
  ]);
  return {
    recommendations: (recs.results || []).map(r => ({ id: r.id, name: r.name || r.title })),
    similar: (sims.results || []).map(r => ({ id: r.id, name: r.name || r.title })),
  };
}

function findClaim(manifest, id) {
  return manifest.items[`${mediaType}:${id}`];
}

function findExemplarConnections(exemplars, related, channelNames) {
  // For each channel, list which exemplars appear in the related lists
  const matches = [];
  const allRelatedIDs = new Set([...related.recommendations.map(r => r.id), ...related.similar.map(r => r.id)]);
  for (const ch of exemplars.channels) {
    // Skip channels whose mediaType doesn't match
    if (ch.mediaType !== mediaType) continue;
  }
  return matches;
}

async function main() {
  const [manifest, exemplars, channelNames] = await Promise.all([
    loadManifest(),
    loadExemplars(),
    loadChannelNames(),
  ]);

  let id;
  if (tmdbIDArg) {
    id = Number(tmdbIDArg);
    console.log(`Looking up ${mediaType} TMDB ID ${id}`);
  } else {
    console.log(`Searching ${mediaType} for "${query}"...\n`);
    const hits = await searchTitle(query);
    if (!hits.length) {
      console.log("No results on TMDB.");
      return;
    }
    console.log("TMDB matches:");
    for (const h of hits) {
      console.log(`  [${h.id}] ${h.name} (${h.year || "?"}) — ${h.overview}`);
    }
    id = hits[0].id;
    console.log(`\nUsing first match: ${hits[0].name} (TMDB ${id})\n`);
  }

  // Claim in the manifest
  const claim = findClaim(manifest, id);
  if (claim) {
    const channelLabels = claim.channels.map(cid => `${cid} ${channelNames[cid] || "?"}`);
    console.log(`✓ CLAIMED in manifest: ${channelLabels.join(", ")}`);
    console.log(`  Source: ${claim.source}`);
  } else {
    console.log(`✗ NOT in manifest. Falls through to rule-based filtering.`);
  }
  console.log("");

  // Exemplar connections — which exemplars list this show as related, per channel
  const reverseHits = [];
  for (const ch of exemplars.channels) {
    if (ch.mediaType !== mediaType) continue;
    // Fetch related for each exemplar and check if our ID shows up
    console.log(`Checking exemplars for CH ${ch.id} ${ch.name}...`);
    const connections = [];
    for (const ex of ch.exemplars) {
      const found = (await tmdb(`/search/${mediaType}`, { query: ex })).results?.[0];
      if (!found) continue;
      const rel = await fetchRelated(found.id);
      const inRecs = rel.recommendations.find(r => r.id === id);
      const inSims = rel.similar.find(r => r.id === id);
      if (inRecs || inSims) {
        const tags = [inRecs && "rec", inSims && "sim"].filter(Boolean).join("+");
        connections.push({ exemplar: ex, exemplarID: found.id, tags });
      }
    }
    if (connections.length) {
      reverseHits.push({ channel: ch, connections });
      console.log(`  Related to ${connections.length} exemplar(s):`);
      for (const c of connections) console.log(`    - ${c.exemplar} (${c.tags})`);
    } else {
      console.log(`  No connections.`);
    }
  }

  if (!reverseHits.length) {
    console.log("\nThis show is not adjacent to any exemplar in TMDB's graph.");
    console.log("To claim it for a channel, add it to that channel's exemplar list.");
  }
}

main().catch(err => {
  console.error("Fatal:", err);
  process.exit(1);
});
