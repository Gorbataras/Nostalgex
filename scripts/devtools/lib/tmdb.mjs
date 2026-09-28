import { readFile, writeFile } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const CACHE_PATH = join(__dirname, "..", "tmdb-keyword-cache.json");

export const tmdbConfigured = Boolean(process.env.TMDB_API_KEY);
const API_KEY = process.env.TMDB_API_KEY;
const BASE = "https://api.themoviedb.org/3";

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function tmdbGet(path) {
  await sleep(80); // ~12 req/sec, well under TMDB limits
  const sep = path.includes("?") ? "&" : "?";
  const url = `${BASE}${path}${sep}api_key=${API_KEY}`;
  try {
    const res = await fetch(url);
    if (!res.ok) return null;
    return res.json();
  } catch {
    return null;
  }
}

let cache = null;
let cacheDirty = false;

async function loadCache() {
  if (cache) return cache;
  try {
    cache = JSON.parse(await readFile(CACHE_PATH, "utf8"));
  } catch {
    cache = {};
  }
  return cache;
}

export async function flushCache() {
  if (cache && cacheDirty) {
    await writeFile(CACHE_PATH, JSON.stringify(cache));
    cacheDirty = false;
  }
}

// TV keywords live on the SHOW in TMDB, so fetch once per show id and let the
// caller fan them out to every episode. Without this, keyword-driven TV
// channels could never be evaluated here and every episode on them looked
// like an orphan.
export async function fetchShowKeywords(tmdbID) {
  if (!tmdbConfigured || !tmdbID) return [];
  const c = await loadCache();
  const key = `t:${tmdbID}`;
  if (key in c) return c[key];
  const data = await tmdbGet(`/tv/${tmdbID}/keywords`);
  const kws = (data?.results || []).map((k) => k.name.toLowerCase());
  c[key] = kws;
  cacheDirty = true;
  return kws;
}

export async function fetchMovieKeywords(item) {
  if (!tmdbConfigured) return [];
  const c = await loadCache();

  // Try by tmdbID first (1 request)
  if (item.tmdbID) {
    const key = `m:${item.tmdbID}`;
    if (key in c) return c[key];
    const data = await tmdbGet(`/movie/${item.tmdbID}/keywords`);
    const kws = (data?.keywords || []).map((k) => k.name.toLowerCase());
    c[key] = kws;
    cacheDirty = true;
    return kws;
  }

  // Fall back to title+year search (2 requests)
  if (item.title && item.year) {
    const key = `s:${item.title.toLowerCase()}:${item.year}`;
    if (key in c) return c[key];
    const q = encodeURIComponent(item.title);
    const search = await tmdbGet(
      `/search/movie?query=${q}&year=${item.year}&include_adult=false`
    );
    const first = search?.results?.[0];
    if (!first) {
      c[key] = [];
      cacheDirty = true;
      return [];
    }
    const kwData = await tmdbGet(`/movie/${first.id}/keywords`);
    const kws = (kwData?.keywords || []).map((k) => k.name.toLowerCase());
    c[key] = kws;
    cacheDirty = true;
    return kws;
  }

  return [];
}
