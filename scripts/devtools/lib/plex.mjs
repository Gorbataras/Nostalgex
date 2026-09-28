// Plex API wrapper. Reads PLEX_URL and PLEX_TOKEN from env at module load.
//
// Notes:
//   - Plex Media Server uses a self-signed TLS cert (the *.plex.direct hostname
//     trick wraps it for browsers, but Node still rejects). We use an undici
//     Agent with rejectUnauthorized: false because this dev tool is hitting
//     YOUR OWN local server — set PLEX_STRICT_TLS=1 to opt back into strict.
//   - 30s per-request timeout so a hung Plex doesn't freeze the audit forever.
//   - One retry on transient fetch failures (TLS handshake hiccup, ECONNRESET).

const PLEX_URL = (process.env.PLEX_URL || "").replace(/\/$/, "");
const PLEX_TOKEN = process.env.PLEX_TOKEN || "";
const STRICT_TLS = process.env.PLEX_STRICT_TLS === "1";

export const plexConfigured = Boolean(PLEX_URL && PLEX_TOKEN);
export const plexHost = PLEX_URL;

// undici (Node's fetch) doesn't take a https.Agent directly. The simplest
// portable workaround is to set NODE_TLS_REJECT_UNAUTHORIZED for the process.
// We do it once at module load if STRICT_TLS isn't set.
if (plexConfigured && !STRICT_TLS) {
  process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
}

const TIMEOUT_MS = 30_000;

async function fetchWithTimeout(url, opts) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    return await fetch(url, { ...opts, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

function describeFetchError(err, path) {
  // undici wraps the real reason in err.cause
  const cause = err?.cause;
  const code = cause?.code || err?.code;
  const causeMsg = cause?.message || err?.message || "unknown";
  if (code === "DEPTH_ZERO_SELF_SIGNED_CERT" || code === "SELF_SIGNED_CERT_IN_CHAIN" || code === "UNABLE_TO_VERIFY_LEAF_SIGNATURE") {
    return `TLS rejected Plex's self-signed cert (${code}). Restart the server WITHOUT PLEX_STRICT_TLS=1, or use http:// instead of https://. Path: ${path}`;
  }
  if (code === "ECONNREFUSED") return `Plex refused the connection — is it running at ${PLEX_URL}? Path: ${path}`;
  if (code === "ENOTFOUND") return `DNS could not resolve ${PLEX_URL}. Path: ${path}`;
  if (code === "ETIMEDOUT" || err?.name === "AbortError") return `Plex timed out after ${TIMEOUT_MS}ms. Path: ${path}`;
  if (code === "ECONNRESET") return `Plex closed the connection (ECONNRESET). Path: ${path}`;
  return `Plex fetch failed (${code || "no code"}): ${causeMsg}. Path: ${path}`;
}

export async function plexGet(path) {
  if (!plexConfigured) throw new Error("PLEX_URL or PLEX_TOKEN missing");
  const url = `${PLEX_URL}${path}${path.includes("?") ? "&" : "?"}X-Plex-Token=${encodeURIComponent(PLEX_TOKEN)}`;
  const opts = { headers: { Accept: "application/json", "X-Plex-Token": PLEX_TOKEN } };

  let lastErr;
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const res = await fetchWithTimeout(url, opts);
      if (!res.ok) {
        const body = await res.text().catch(() => "");
        throw new Error(`Plex ${res.status} on ${path}${body ? ` — ${body.slice(0, 200)}` : ""}`);
      }
      return await res.json();
    } catch (err) {
      lastErr = err;
      // Retry only transient network failures, not HTTP errors
      const code = err?.cause?.code || err?.code;
      const isTransient = ["ECONNRESET", "ETIMEDOUT", "EPIPE", "UND_ERR_SOCKET"].includes(code) || err?.name === "AbortError";
      if (!isTransient || attempt === 1) {
        if (err.message?.startsWith("Plex ")) throw err; // already a clean HTTP error
        throw new Error(describeFetchError(err, path));
      }
      // brief backoff before retry
      await new Promise((r) => setTimeout(r, 300));
    }
  }
  throw lastErr;
}

export async function listSections() {
  const data = await plexGet("/library/sections");
  return (data.MediaContainer?.Directory || []).filter((s) => s.type === "movie" || s.type === "show");
}

// Lightweight item list — one call per section. Used by the schedule explorer.
// Note: does NOT include per-Stream detail. For audit, use getItemDetails().
export async function listMovieItems(sectionKey) {
  // includeGuids=1 is what makes Plex return the Guid array (tmdb://, imdb://,
  // tvdb://). Without it nothing has a TMDB id and the manifest can't claim
  // anything. The Swift app requests it too (PlexAPIService, section fetch).
  const data = await plexGet(`/library/sections/${sectionKey}/all?includeGuids=1`);
  return data.MediaContainer?.Metadata || [];
}

export async function listEpisodeItems(sectionKey) {
  // Plex keeps genres, studio and the TMDB id on the SHOW record, not on the
  // episode. The Swift app fetches the shows for the section and joins each
  // episode to its show through grandparentRatingKey (PlexAPIService,
  // showsByKey). Mirror that here and hang the show on `_show` so
  // normalizeItem can inherit from it. Before this, every episode had no
  // genres and no TMDB id, so every genre-gated TV channel came back empty.
  const [leaves, shows] = await Promise.all([
    plexGet(`/library/sections/${sectionKey}/allLeaves?includeGuids=1`),
    plexGet(`/library/sections/${sectionKey}/all?type=2&includeGuids=1`),
  ]);
  const showsByKey = new Map((shows.MediaContainer?.Metadata || []).map((sh) => [String(sh.ratingKey), sh]));
  const eps = leaves.MediaContainer?.Metadata || [];
  let unjoined = 0;
  for (const ep of eps) {
    const show = showsByKey.get(String(ep.grandparentRatingKey));
    if (show) ep._show = show; else unjoined++;
  }
  // The Swift app drops episodes it can't join. We keep them so they surface
  // in Coverage as orphans with a visible reason instead of vanishing.
  if (unjoined) console.warn(`[plex] section ${sectionKey}: ${unjoined} episodes have no parent show record; keeping them with their own sparse metadata`);
  return eps;
}

export async function getItemDetails(ratingKey) {
  const data = await plexGet(`/library/metadata/${ratingKey}`);
  return data.MediaContainer?.Metadata?.[0] || null;
}

// Mirrors the Swift detection in PlexAPIService.parseMovieItem — sections
// whose title matches "music video", "music", "mv"/"mvs" get tagged as the
// musicVideo library source so the source-restricted channels work.
const MUSIC_VIDEO_SECTION_RE = /music.?video|^music$|^mv[s]?$/i;

export function detectLibrarySource(sectionTitle, sectionType) {
  if (sectionType === "show") return "tv";
  if (sectionType === "movie" && MUSIC_VIDEO_SECTION_RE.test(sectionTitle || "")) return "musicVideo";
  return "movie";
}

// Normalize a Plex Metadata entry into the shape the schedule/filter code expects.
// Fields mirror PlexMediaItem in the Swift app (best-effort — no enrichment data).
//
// Critical detail for episodes: in the Swift app, `item.title` is the SHOW
// title (e.g. "Animaniacs"), NOT "Animaniacs — Puttin' on the Blitz". The
// `titleContains` filter runs against that, so the show name is what matches.
// We mirror that exactly. `displayTitle` is the "Show — Episode" string the UI
// shows; never used for filtering.
export function normalizeItem(raw, sectionType, sectionTitle = "") {
  const dur = raw.duration ? Math.round(raw.duration / 60000) : 0; // ms → min
  const source = detectLibrarySource(sectionTitle, sectionType);
  const isEpisode = sectionType === "show";
  // Episodes inherit genres and studio from their show (see listEpisodeItems).
  const meta = isEpisode && raw._show ? raw._show : raw;
  const genres = (meta.Genre || []).map((g) => (g.tag || "").toLowerCase()).filter(Boolean);
  const studio = (meta.studio || "").trim() || null;
  // For episodes Plex returns the episode in `title` and the show in
  // `grandparentTitle`. We use the show name for filtering and assemble the
  // display title separately.
  const showOrMovieTitle = isEpisode ? (raw.grandparentTitle || raw.title) : raw.title;
  const episodeTitle = isEpisode ? raw.title : null;
  const displayTitle = isEpisode && episodeTitle && episodeTitle !== showOrMovieTitle
    ? `${showOrMovieTitle} — ${episodeTitle}`
    : showOrMovieTitle;
  const tmdbID = parseTmdbIdFromPlex(raw, isEpisode);

  return {
    ratingKey: raw.ratingKey,
    title: showOrMovieTitle, // used for filtering — matches Swift item.title
    episodeTitle, // null for movies
    displayTitle, // UI-only "Show — Episode" string
    type: isEpisode ? "episode" : "movie",
    librarySource: source, // "movie" | "tv" | "musicVideo"
    year: raw.year || raw.parentYear || raw.grandparentYear || raw._show?.year || null,
    duration: dur, // minutes
    viewCount: raw.viewCount || 0,
    contentRating: (raw.contentRating || "").trim() || null,
    addedAt: raw.addedAt || 0,
    genres,
    studio,
    summary: raw.summary || "",
    tmdbID,
  };
}

/** Plex GUIDs look like `tmdb://456` or agent URLs containing `tmdb://456`. */
export function parseTmdbIdFromPlex(raw, isEpisode = false) {
  const candidates = [];
  // For episodes the SHOW's TMDB id comes first: the manifest keys TV as
  // tv:<show id> and the Swift app reads show.tmdbID, never the episode's.
  if (isEpisode && Array.isArray(raw._show?.Guid)) candidates.push(...raw._show.Guid.map((g) => g.id));
  if (Array.isArray(raw.Guid)) candidates.push(...raw.Guid.map((g) => g.id));
  if (raw.guid) candidates.push(raw.guid);
  if (isEpisode && raw.grandparentGuid) candidates.push(raw.grandparentGuid);
  if (isEpisode && raw.parentGuid) candidates.push(raw.parentGuid);
  for (const id of candidates) {
    const m = String(id).match(/tmdb:\/\/(\d+)/);
    if (m) return m[1];
  }
  return null;
}
