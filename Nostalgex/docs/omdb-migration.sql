-- Phase 2: OMDb enrichment layer
-- Run historically in Supabase SQL editor against the `tmdb_enrichments`
-- table, which was later renamed to `media_enrichments` (see
-- rls-migration.sql and rls-tighten-media-enrichments.sql, both of which
-- use the current name). Kept here as a historical record — do not run
-- this against the current schema; the columns it adds already exist.

-- Add OMDb columns to existing table (all nullable for backwards compat)
alter table tmdb_enrichments add column if not exists imdb_id text;
alter table tmdb_enrichments add column if not exists imdb_rating numeric;
alter table tmdb_enrichments add column if not exists imdb_votes integer;
alter table tmdb_enrichments add column if not exists rt_score integer;
alter table tmdb_enrichments add column if not exists metacritic_score integer;
alter table tmdb_enrichments add column if not exists awards text;

-- Index for IMDb lookups
create index if not exists tmdb_enrichments_imdb_id_idx on tmdb_enrichments(imdb_id);

-- Verify (historical, against the old table name)
-- select column_name, data_type from information_schema.columns where table_name = 'tmdb_enrichments';
