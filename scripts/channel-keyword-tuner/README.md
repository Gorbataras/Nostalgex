# Channel Keyword Tuner

Derives the TMDB keyword vocabulary for a Nostalgex channel from a curated list
of exemplar shows/movies. The output is what you paste into `channels.json`.

## Why this exists

Channel rules tuned against one Plex library don't generalize — they break for
other users. Instead, we define each channel by 10–20 canonical exemplars
("these shows unambiguously belong on MAN CAVE") and let TMDB's tagged keywords
become the channel's semantic fingerprint.

## Usage

```bash
export TMDB_API_KEY=your_key_here

# Run all channels in exemplars.json
node scripts/channel-keyword-tuner/index.mjs

# Run a single channel
node scripts/channel-keyword-tuner/index.mjs --channel 56
```

Output: `scripts/channel-keyword-tuner/report.md`

## Workflow

1. Add or edit a channel entry in `exemplars.json` with 10–20 canonical titles
2. Run the script
3. Open `report.md`, copy the suggested `keywords` + `keywordsRequireAnyGenre`
   block into `channels.json`
4. Tune the exemplar list and re-run if the result looks off

## Notes

- Uses the first TMDB search hit per title — check the "matched" name in the
  audit section if a result looks wrong, and add the year to the exemplar
  title to disambiguate (TMDB search supports `Title (Year)` patterns).
- TMDB free tier is 50 req/sec, well above what we need.
- Exemplar lists are inputs to this script, not shipped to the app.
