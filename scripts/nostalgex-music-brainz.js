/**
 * MusicBrainz enrichment for Nostalgex web tuner (browser).
 * Free API — no account/key; 1 request/sec; meaningful User-Agent required.
 * https://musicbrainz.org/doc/MusicBrainz_API
 */
(function (global) {
  const BASE = 'https://musicbrainz.org/ws/2';
  const USER_AGENT = 'Nostalgex/1.0.2 (https://www.nostalgex.app; web-tuner)';
  const CACHE_KEY = 'nostalgex_music_video_enrichments_v1';
  const MIN_INTERVAL_MS = 1050;

  let lastRequestAt = 0;
  let cache = {};

  function stripYearSuffix(title) {
    return String(title || '').replace(/\s+\(\d{4}\)$/, '').trim();
  }

  function parseTitle(raw) {
    const cleaned = stripYearSuffix(raw);
    const dash = cleaned.indexOf(' - ');
    if (dash > 0) {
      const artist = cleaned.slice(0, dash).trim();
      const song = cleaned.slice(dash + 3).trim();
      if (artist && song) return { artist, song };
    }
    const byIdx = cleaned.toLowerCase().lastIndexOf(' by ');
    if (byIdx > 0) {
      const song = cleaned.slice(0, byIdx).trim();
      const artist = cleaned.slice(byIdx + 4).trim();
      if (artist && song) return { artist, song };
    }
    return { artist: null, song: cleaned };
  }

  function mapTagsToChannelGenres(tags) {
    const out = [];
    const add = (g) => {
      if (!out.some((x) => x.toLowerCase() === g.toLowerCase())) out.push(g);
    };
    for (const tag of tags) {
      const t = String(tag).toLowerCase();
      if (t.includes('pop') && !t.includes('k-pop')) add('Pop');
      if (t.includes('rock')) {
        if (t.includes('alternative') || t.includes('indie')) {
          add('Alternative Rock');
          add('Indie Rock');
        } else if (t.includes('hard rock') || t.includes('hard-rock')) add('Hard Rock');
        else if (t.includes('classic rock')) add('Classic Rock');
        else add('Rock');
      }
      if (t.includes('country')) {
        add('Country');
        if (t.includes('rock')) add('Country Rock');
      }
      if (t.includes('hip hop') || t.includes('hip-hop')) {
        add('Hip-Hop');
        add('Hip Hop');
      }
      if (t === 'rap' || t.includes('gangsta')) add('Rap');
      if (t.includes('r&b') || t.includes('rhythm and blues') || t === 'soul') {
        add('R&B');
        add('Soul');
      }
      if (t.includes('acoustic')) add('Acoustic');
      if (t.includes('electronic') || t.includes('dance') || t.includes('edm') ||
          t.includes('house') || t.includes('techno') || t.includes('trance')) add('Dance');
      if (t.includes('metal')) {
        add('Metal');
        add('Hard Rock');
        add('Rock');
      }
      if (t.includes('punk')) {
        add('Rock');
        add('Alternative');
      }
      if (t.includes('folk')) add('Acoustic');
      if (t.includes('latin') || t.includes('reggaeton') || t.includes('reggaetón')) add('Latin');
      if (t.includes('funk')) add('Funk');
      if (t.includes('disco')) add('Disco');
    }
    return out;
  }

  function primaryArtistName(rec) {
    const credits = rec['artist-credit'];
    if (!Array.isArray(credits)) return null;
    for (const credit of credits) {
      if (credit.name) return credit.name;
      if (credit.artist && credit.artist.name) return credit.artist.name;
    }
    return null;
  }

  function firstReleaseYear(rec) {
    const releases = rec.releases;
    if (!Array.isArray(releases)) return null;
    for (const release of releases) {
      const date = release.date;
      if (date && date.length >= 4) {
        const y = parseInt(date.slice(0, 4), 10);
        if (!Number.isNaN(y)) return y;
      }
    }
    return null;
  }

  function extractTagNames(rec) {
    if (!Array.isArray(rec.tags)) return [];
    return rec.tags.map((t) => t.name).filter(Boolean);
  }

  async function rateLimitedFetch(url) {
    const elapsed = Date.now() - lastRequestAt;
    if (elapsed < MIN_INTERVAL_MS) {
      await new Promise((r) => setTimeout(r, MIN_INTERVAL_MS - elapsed));
    }
    lastRequestAt = Date.now();
    const res = await fetch(url, {
      headers: {
        Accept: 'application/json',
        'User-Agent': USER_AGENT,
      },
    });
    if (!res.ok) throw new Error(`MusicBrainz HTTP ${res.status}`);
    return res.json();
  }

  function escapeQuery(s) {
    return String(s).replace(/"/g, '');
  }

  async function searchBestRecording(songTitle, artist, year) {
    const parts = [`recording:"${escapeQuery(songTitle)}"`, 'video:true'];
    if (artist) parts.push(`artist:"${escapeQuery(artist)}"`);
    const query = encodeURIComponent(parts.join(' AND '));
    const json = await rateLimitedFetch(`${BASE}/recording?query=${query}&fmt=json&limit=10`);
    const recordings = json.recordings || [];
    if (!recordings.length) return null;

    const songLower = songTitle.toLowerCase();
    let best = null;
    let bestRank = -1;

    for (const rec of recordings) {
      if (!rec.id || !rec.title) continue;
      const score = rec.score || 0;
      const artistName = primaryArtistName(rec);
      const recYear = firstReleaseYear(rec);
      let rank = score;
      const titleLower = rec.title.toLowerCase();
      if (titleLower === songLower) rank += 40;
      else if (titleLower.includes(songLower) || songLower.includes(titleLower)) rank += 20;
      if (artist && artistName && artistName.toLowerCase().includes(artist.toLowerCase())) rank += 25;
      if (year && recYear === year) rank += 15;
      else if (year && recYear != null && Math.abs(year - recYear) <= 1) rank += 8;
      if (rank > bestRank) {
        bestRank = rank;
        best = { mbid: rec.id, title: rec.title, artist: artistName, year: recYear };
      }
    }
    return best;
  }

  async function lookupRecording(mbid) {
    const json = await rateLimitedFetch(
      `${BASE}/recording/${mbid}?inc=artist-credits+tags+releases&fmt=json`
    );
    if (!json.title) return null;
    const tags = extractTagNames(json);
    return {
      mbid,
      recordingTitle: json.title,
      artist: primaryArtistName(json),
      genres: mapTagsToChannelGenres(tags),
      releaseYear: firstReleaseYear(json),
    };
  }

  async function resolveRecording(title, artist, year) {
    const song = stripYearSuffix(title);
    if (!song) return null;
    const hit = await searchBestRecording(song, artist, year);
    if (!hit) return null;
    try {
      const detailed = await lookupRecording(hit.mbid);
      if (detailed) return detailed;
    } catch (e) {
      console.warn('[MusicBrainz] lookup failed', hit.mbid, e);
    }
    return {
      mbid: hit.mbid,
      recordingTitle: hit.title,
      artist: hit.artist,
      genres: [],
      releaseYear: hit.year,
    };
  }

  function loadDiskCache() {
    try {
      const raw = localStorage.getItem(CACHE_KEY);
      if (!raw) {
        cache = {};
        return;
      }
      cache = JSON.parse(raw) || {};
    } catch {
      cache = {};
    }
  }

  function saveDiskCache() {
    try {
      localStorage.setItem(CACHE_KEY, JSON.stringify(cache));
    } catch (e) {
      console.warn('[MusicBrainz] cache save failed', e);
    }
  }

  function plexGenresAreThin(genres) {
    const useful = (genres || []).filter((g) => {
      const l = String(g).toLowerCase();
      return !l.includes('music video') && l !== 'music' && l !== 'musical';
    });
    return useful.length === 0;
  }

  function mergeGenres(plex, resolved) {
    const out = [...(plex || [])];
    for (const g of resolved || []) {
      if (!out.some((x) => x.toLowerCase() === g.toLowerCase())) out.push(g);
    }
    return out;
  }

  function isMusicVideoItem(item) {
    return item && item.librarySource === 'musicVideo' && item.type !== 'episode';
  }

  function buildMusicMeta(item) {
    const parts = [];
    if (item.artist) parts.push(item.artist);
    if (item.year) parts.push(String(item.year));
    const genres = musicGenreDisplay(item);
    if (genres) parts.push(genres);
    if (item.duration) parts.push(formatDuration(item.duration));
    return parts.join(' · ');
  }

  function formatDuration(minutes) {
    const h = Math.floor(minutes / 60);
    const m = minutes % 60;
    return h > 0 ? `${h}h ${m}m` : `${m}m`;
  }

  function musicGenreDisplay(item) {
    if (!isMusicVideoItem(item)) return null;
    const useful = (item.genres || []).filter((g) => {
      const l = String(g).toLowerCase();
      return !l.includes('music video') && l !== 'music' && l !== 'musical';
    });
    if (!useful.length) return null;
    return useful.slice(0, 4).join(' · ');
  }

  function itemDisplayLine(item) {
    if (!isMusicVideoItem(item)) {
      if (item.episodeTitle) return `${item.title}: ${item.episodeTitle}`;
      return item.title || '';
    }
    if (item.artist) return `${item.artist} — ${item.title}`;
    return item.title || '';
  }

  function applyEnrichmentToItem(item, enr) {
    if (!enr || !isMusicVideoItem(item)) return item;
    const title = (enr.recordingTitle || item.title || '').trim() || item.title;
    const artist = enr.artist || item.artist || null;
    const genres = mergeGenres(item.genres, enr.genres);
    const year = item.year || enr.releaseYear || '';
    const updated = {
      ...item,
      title,
      artist,
      genres,
      year,
      meta: buildMusicMeta({ ...item, title, artist, genres, year }),
    };
    return updated;
  }

  function itemsWithDisplayMetadata(items) {
    return items.map((item) => {
      const enr = cache[item.ratingKey];
      return enr ? applyEnrichmentToItem(item, enr) : item;
    });
  }

  function parseMusicVideoFromPlex(item, rawTitle) {
    const parent = item.parentTitle || '';
    const grandparent = item.grandparentTitle || '';
    const artistHint = parent || grandparent || null;
    const parsed = parseTitle(rawTitle);
    return {
      title: parsed.song || rawTitle,
      artist: artistHint || parsed.artist || null,
    };
  }

  async function enrichMusicVideos(items, onProgress) {
    loadDiskCache();
    const mv = items.filter(isMusicVideoItem);
    if (!mv.length) return { enriched: 0, total: 0 };

    let updated = 0;
    let done = 0;
    for (const item of mv) {
      done += 1;
      if (onProgress) onProgress(done, mv.length, item.title);

      const existing = cache[item.ratingKey];
      if (existing && (existing.musicBrainzID || existing.hasUsefulGenres)) {
        continue;
      }
      if (existing && !plexGenresAreThin(item.genres) && existing.artist) {
        continue;
      }

      const parsed = parseTitle(item.title);
      const artistHint = item.artist || parsed.artist;
      const songTitle = parsed.song;
      const yearNum = item.year ? parseInt(String(item.year), 10) : null;
      const year = Number.isNaN(yearNum) ? null : yearNum;

      try {
        const match = await resolveRecording(songTitle, artistHint, year);
        const enr = {
          ratingKey: item.ratingKey,
          recordingTitle: match ? match.recordingTitle : songTitle,
          artist: (match && match.artist) || artistHint || null,
          musicBrainzID: match ? match.mbid : null,
          genres: mergeGenres(item.genres, match ? match.genres : []),
          releaseYear: match ? match.releaseYear : null,
          fetchedAt: Date.now(),
        };
        enr.hasUsefulGenres = enr.genres.some((g) => {
          const l = g.toLowerCase();
          return !l.includes('music video') && l !== 'music' && l !== 'musical';
        });
        cache[item.ratingKey] = enr;
        updated += 1;
      } catch (e) {
        console.warn('[MusicBrainz] resolve failed', item.title, e);
        cache[item.ratingKey] = {
          ratingKey: item.ratingKey,
          recordingTitle: songTitle,
          artist: artistHint || null,
          musicBrainzID: null,
          genres: item.genres || [],
          releaseYear: null,
          fetchedAt: Date.now(),
          hasUsefulGenres: false,
        };
      }
    }
    if (updated) saveDiskCache();
    return { enriched: updated, total: mv.length };
  }

  function titleHaystack(item) {
    const parts = [stripYearSuffix(item.title || '')];
    if (item.artist) parts.push(item.artist);
    return parts.join(' ').toLowerCase();
  }

  global.NostalgexMusicBrainz = {
    parseTitle,
    stripYearSuffix,
    parseMusicVideoFromPlex,
    isMusicVideoItem,
    itemDisplayLine,
    musicGenreDisplay,
    buildMusicMeta,
    titleHaystack,
    loadDiskCache,
    saveDiskCache,
    enrichMusicVideos,
    itemsWithDisplayMetadata,
    applyEnrichmentToItem,
    mapTagsToChannelGenres,
  };
})(typeof globalThis !== 'undefined' ? globalThis : window);
