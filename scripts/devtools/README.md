# Nostalgex Devtools

Local web UIs for validating the Nostalgex channel rotation and Plex library health. **Local only — never deployed, never shipped in the app.**

## What's in here

- **Schedule Explorer** (`/schedule.html`) — search every airing across all channels for the past 7 days through next 7 days. Validates that titles you expect to see in rotation actually are, and confirms the deterministic algorithm puts them where you expect.
- **Channel Pools** (`/pools.html`) — pick a channel, see exactly which titles are eligible plus the filter rules side-by-side. Decade/genre/type breakdowns make rule mistakes obvious at a glance.
- **Library Audit** (`/audit.html`) — scans every movie / episode in your Plex library and flags files most likely to cause tvOS playback issues (no audio, lossless audio AVPlayer can't decode, MKV containers, HEVC 10-bit, AV1, wrong default language, very high bitrate).
- **Channel Memberships** (`/memberships.html`) — inspect the TMDB membership manifest: which titles are claimed for which channels, by exemplar or by TMDB's recommendation graph.
- **Channel Coverage** (`/coverage.html`) — every item in the library and how many channels pull it in. Finds orphans (items in zero channels), groups them by the most likely reason, flags channels below their `minItems`, and answers "where is X?" for any title. See *How coverage works* below before trusting the numbers.

## Run it

Put credentials in `.env` at the **repo root** (gitignored, set once):

```
PLEX_URL=https://your-plex.example.com:32400
PLEX_TOKEN=your-plex-token
TMDB_API_KEY=your-tmdb-key
```

Then, from the repo root:

```bash
npm run snapshot        # build scripts/devtools/snapshot.json from Plex (+ TMDB keywords for movies)
npm run devtools        # start the server → http://localhost:3030
npm run devtools:full   # both
```

The npm scripts load `.env` via `node --env-file-if-exists`; nothing in the devtools reads `.env` on its own, so running `node server.mjs` directly needs the variables exported in your shell.

Schedule, Pools and Coverage read the snapshot. Only Library Audit needs a live Plex connection. Rebuild the snapshot after a library change or a rule change; it does not refresh itself.

**The CLEAR button in the snapshot bar deletes `snapshot.json`.** It cannot be undone, and there is no fallback unless Plex credentials are set. Rebuild with `npm run snapshot`.

Optional: `PORT=8080 npm run devtools` to bind a different port.

## How to find your Plex token

Plex Web → any item → ⋯ → **Get Info** → **View XML** → the `X-Plex-Token=…` query param in the URL bar is your token.

## How the schedule explorer works

The Nostalgex schedule is **fully deterministic** — every airing is computed from `unix time + channel id + day number + golden-ratio offset` against the channel's pool. That means past airings are reproducible without any logging: the explorer just replays the algorithm for any timestamp.

The JS implementation in `lib/schedule.mjs` is a port of `Nostalgex/Models/ChannelSchedule.swift`. If you change the algorithm in Swift, port the change here too so the explorer stays accurate.

### Caveats

The dev server doesn't have TMDB / OMDb enrichment data, so it can't evaluate channels that filter by **keywords, networks, prodCos, or ratingMin**. Channels using those rules will show fewer (or zero) airings here than in the actual app. The Schedule Explorer flags affected channels with a ⚠ in the channel dropdown.

For year, content rating, runtime, genre, watched-state, and title filters: results match the app exactly.

## How coverage works

Coverage inverts the snapshot: `build-snapshot.mjs` records each channel's `poolKeys`, and `lib/coverage.mjs` flips that into *item → channels*. An item in zero pools is an **orphan**.

**Read every number as a lower bound.** The snapshot is produced by the shared JS filter, not by the tvOS app. The filter cannot evaluate `networks`, `excludeNetworks`, `excludeKeywords` or `ratingMin`, only partially evaluates `studios` / `productionCompanies` (Plex studio field only), and TMDB keyword enrichment runs for movies only. So a channel that relies on those rules under-populates here, and an orphan is a *candidate to check*, not a confirmed gap. The page separates orphans explained by those tool limits from the rest, and the channel table shows which rules each channel uses that the tool can't fully evaluate.

Orphans are grouped by the first reason that applies, in this order:

| Group | Meaning | What to do |
|---|---|---|
| No TMDB id from Plex | Plex never matched the item to TMDB, so manifest claims and keyword rules can't reach it | Plex → item → ⋯ → Match. Then rescan and rebuild the snapshot |
| No genres in Plex | Most channels gate on genre | Refresh metadata in Plex; check the library agent has genres enabled |
| No year in Plex | Decade channels need a year | Fix the match or edit the year |
| TV item: tool has no keyword data | **Tool limitation.** Keyword-driven TV channels can't be evaluated here | Probably fine in the app. Verify on the device, or add TV keyword enrichment to `build-snapshot.mjs` |
| Would pass a channel this tool can't evaluate | **Tool limitation.** With `networks` / `ratingMin` / `excludeKeywords` set aside, the item passes a channel that uses them; the app evaluates those with TMDB/OMDb data | Probably pooled there in the app. The likely channels are shown per item |
| Has metadata, matched nothing | Id, genres and year are present but no rule or claim accepts it | Either the lineup has no home for this kind of item, or a rule is tighter than intended. Use Pools to inspect the channel you expected |

A **"claimed" badge** on an orphan means `channels-memberships.json` claims it for a channel but the pool rejected it. A manifest claim only bypasses `genres.include`; the channel's `type`, `yearRange`, `titleContains` and `genres.exclude` still apply, so one of those vetoed it. That is the most precise "look here" signal the tool gives.

Episodes are collapsed to their show in every table, so an unmatched series reads as one problem rather than two hundred.

## How the audit works

The audit hits the Plex API directly, walks every section, fetches detailed Media/Part/Stream metadata for each item, and runs the rule set in `lib/audit.mjs`. Same rules as the original CLI version, just exposed via HTTP.

| Tag | Severity | What it means |
|---|---|---|
| `no-audio-track` | high | File is missing an audio stream entirely |
| `lossless-audio:*` | high | TrueHD / DTS-HD MA / Atmos — AVPlayer can't decode natively, audio may drop |
| `container-mkv` | medium | MKV forces remux/transcode wrap on tvOS — slow start |
| `hevc-10bit` | medium | HEVC 10-bit can stutter on older Apple TVs, HDR may force transcode |
| `av1-codec` | medium | AV1 not hardware-decoded on most Apple TV generations |
| `default-audio:*` | low | Default audio track is non-English — viewer may hear the wrong language |
| `very-high-bitrate` | low | >60 Mbps — may stutter on limited bandwidth |

### Fixing flagged files

- **TrueHD / DTS-HD MA**: re-encode the audio track to AC3 or AAC. HandBrake preset "Apple TV 4K" → Audio tab → Codec: AC3 Passthru with AAC fallback.
- **MKV containers**: remux to MP4 with `ffmpeg -i in.mkv -c copy out.mp4` (no re-encode needed).
- **HEVC 10-bit stutter**: usually fine on Apple TV 4K (2nd gen+); flag is informational. Re-encode to 8-bit H.264 if targeting older devices.
- **Wrong default audio**: in Plex Web → episode/movie → Audio & Subtitles → "Set Audio as Default" for the English track.

## Architecture

```
server.mjs           # zero-framework Node http server, static + JSON API
build-snapshot.mjs   # Plex → snapshot.json (pools + schedules for every channel)
lib/
  plex.mjs           # Plex API wrapper
  tmdb.mjs           # TMDB keyword enrichment (movies), cached on disk
  schedule.mjs       # JS port of the schedule algorithm
  channels.mjs       # channels.json loader + pool filter (shared with plex-tuner.html)
  memberships.mjs    # channels-memberships.json + exemplars.json readers
  snapshot.mjs       # snapshot store (in-memory + snapshot.json on disk)
  coverage.mjs       # item → channels inversion, orphan reasons, thin channels
  audit.mjs          # audit rules + scan runner
public/
  index.html         # landing
  schedule.html      # schedule explorer
  pools.html         # channel pool inspector
  memberships.html   # manifest inspector
  coverage.html      # channel coverage
  audit.html         # library audit
  snapshot-bar.js    # shared snapshot status bar
  styles.css         # shared dark/cyan/mono styles
```

No build step. No dependencies. `npm run devtools`.
