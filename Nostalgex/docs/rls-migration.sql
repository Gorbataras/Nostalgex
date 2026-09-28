-- Enable Row Level Security on media_enrichments
-- Run in Supabase SQL editor
--
-- Context: the anon key is embedded in the tvOS app binary and extractable
-- by anyone. Without RLS, any holder of the key could wipe or poison the
-- cache. With RLS + these policies, the anon role can only perform the
-- operations the app actually needs: SELECT + INSERT + UPDATE.

alter table public.media_enrichments enable row level security;

-- SELECT: anyone with the anon key can read the cache (this is public
-- movie/TV metadata, not sensitive user data).
create policy "anon_read_media_enrichments"
  on public.media_enrichments
  for select
  to anon
  using (true);

-- INSERT: anon can add new enrichments (populated by the app after
-- TMDB/OMDb fetch).
create policy "anon_insert_media_enrichments"
  on public.media_enrichments
  for insert
  to anon
  with check (true);

-- UPDATE: anon can update existing rows (needed for upsert /
-- merge-duplicates behavior used by the EnrichmentService).
create policy "anon_update_media_enrichments"
  on public.media_enrichments
  for update
  to anon
  using (true)
  with check (true);

-- NOTE: DELETE is intentionally NOT granted. The app never deletes
-- enrichment rows, so blocking DELETE prevents malicious wipes even
-- if the anon key leaks (which it will, since it's in the binary).

-- Verify
-- select polname, cmd, roles from pg_policies where tablename = 'media_enrichments';
