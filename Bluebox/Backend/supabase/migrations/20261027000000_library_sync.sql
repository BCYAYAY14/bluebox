-- Bluebox library sync: watch progress and watchlist, one row per (user, media key).
--
-- Every row belongs to auth.uid(). Clients never send user_id: the column
-- defaults to auth.uid() and RLS rejects anything else. Writes go through the
-- sync_* functions, which apply the same merge rules as the app
-- (Domain/WatchProgress.swift ProgressMerge, Domain/WatchlistSync.swift
-- WatchlistMerge) so every device converges on the same value.
--
-- server_updated_at is set by the database whenever a row actually changes.
-- Clients pull with a keyset cursor on (server_updated_at, media_key).

create table public.watch_progress (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  media_key text not null check (char_length(media_key) between 1 and 200),
  position double precision not null check (position >= 0),
  duration double precision check (duration is null or duration > 0),
  is_completed boolean not null default false,
  updated_at timestamptz not null,
  device_id text check (device_id is null or char_length(device_id) <= 100),
  server_updated_at timestamptz not null default clock_timestamp(),
  primary key (user_id, media_key)
);

create table public.watchlist_entries (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  media_key text not null check (char_length(media_key) between 1 and 200),
  title jsonb not null check (octet_length(title::text) <= 16384),
  added_at timestamptz not null,
  is_removed boolean not null default false,
  updated_at timestamptz not null,
  server_updated_at timestamptz not null default clock_timestamp(),
  primary key (user_id, media_key)
);

create index watch_progress_pull_idx on public.watch_progress (user_id, server_updated_at, media_key);
create index watchlist_entries_pull_idx on public.watchlist_entries (user_id, server_updated_at, media_key);

-- server_updated_at always comes from the database clock, never the client.
create function public.touch_server_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.server_updated_at := clock_timestamp();
  return new;
end;
$$;

create trigger watch_progress_touch before insert or update on public.watch_progress
  for each row execute function public.touch_server_updated_at();
create trigger watchlist_entries_touch before insert or update on public.watchlist_entries
  for each row execute function public.touch_server_updated_at();

-- Row level security: a user sees and changes only their own rows.
alter table public.watch_progress enable row level security;
alter table public.watchlist_entries enable row level security;

create policy "own progress: select" on public.watch_progress
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "own progress: insert" on public.watch_progress
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "own progress: update" on public.watch_progress
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "own progress: delete" on public.watch_progress
  for delete to authenticated using ((select auth.uid()) = user_id);

create policy "own watchlist: select" on public.watchlist_entries
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "own watchlist: insert" on public.watchlist_entries
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "own watchlist: update" on public.watchlist_entries
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "own watchlist: delete" on public.watchlist_entries
  for delete to authenticated using ((select auth.uid()) = user_id);

revoke all on public.watch_progress, public.watchlist_entries from anon;
grant select, insert, update, delete on public.watch_progress, public.watchlist_entries to authenticated;

-- Upserts a batch of progress records and returns the stored row for every key
-- in the batch, so the client learns the winner even when its write lost.
-- Incoming wins when (matching ProgressMerge): newer updated_at; on a tie,
-- completed beats not completed; then larger position; then larger device_id.
create function public.sync_progress(items jsonb)
returns setof public.watch_progress
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) > 500 then
    raise exception 'items must be an array of at most 500 records' using errcode = '22023';
  end if;

  insert into public.watch_progress as e (media_key, position, duration, is_completed, updated_at, device_id)
  select distinct on (i.media_key)
         i.media_key, i.position, i.duration, coalesce(i.is_completed, false), i.updated_at, i.device_id
  from jsonb_to_recordset(items) as i (
    media_key text, position double precision, duration double precision,
    is_completed boolean, updated_at timestamptz, device_id text)
  order by i.media_key, i.updated_at desc
  on conflict (user_id, media_key) do update set
    position = excluded.position,
    duration = excluded.duration,
    is_completed = excluded.is_completed,
    updated_at = excluded.updated_at,
    device_id = excluded.device_id
  where excluded.updated_at > e.updated_at
     or (excluded.updated_at = e.updated_at and (
            (excluded.is_completed and not e.is_completed)
         or (excluded.is_completed = e.is_completed and (
                excluded.position > e.position
             or (excluded.position = e.position
                 and coalesce(excluded.device_id, '') > coalesce(e.device_id, ''))))));

  return query
    select p.* from public.watch_progress p
    where p.user_id = auth.uid()
      and p.media_key in (select x ->> 'media_key' from jsonb_array_elements(items) as x);
end;
$$;

-- Same for watchlist entries. Incoming wins when (matching WatchlistMerge):
-- newer updated_at; on a tie, present beats removed.
create function public.sync_watchlist(items jsonb)
returns setof public.watchlist_entries
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) > 500 then
    raise exception 'items must be an array of at most 500 records' using errcode = '22023';
  end if;

  insert into public.watchlist_entries as e (media_key, title, added_at, is_removed, updated_at)
  select distinct on (i.media_key)
         i.media_key, i.title, i.added_at, coalesce(i.is_removed, false), i.updated_at
  from jsonb_to_recordset(items) as i (
    media_key text, title jsonb, added_at timestamptz, is_removed boolean, updated_at timestamptz)
  order by i.media_key, i.updated_at desc
  on conflict (user_id, media_key) do update set
    title = excluded.title,
    added_at = excluded.added_at,
    is_removed = excluded.is_removed,
    updated_at = excluded.updated_at
  where excluded.updated_at > e.updated_at
     or (excluded.updated_at = e.updated_at and e.is_removed and not excluded.is_removed);

  return query
    select w.* from public.watchlist_entries w
    where w.user_id = auth.uid()
      and w.media_key in (select x ->> 'media_key' from jsonb_array_elements(items) as x);
end;
$$;

revoke all on function public.sync_progress(jsonb), public.sync_watchlist(jsonb) from public, anon;
grant execute on function public.sync_progress(jsonb), public.sync_watchlist(jsonb) to authenticated;
revoke all on function public.touch_server_updated_at() from public, anon, authenticated;
