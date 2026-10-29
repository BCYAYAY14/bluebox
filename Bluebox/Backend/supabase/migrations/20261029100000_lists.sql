-- Lists: My List stays the watchlist (so Trakt keeps working), plus each
-- profile's own lists ("Halloween", "Watch with Mia") and the titles on them.
-- Nothing existing is rewritten: My List only gains a nullable manual order.
--
-- Both tables sync like the watchlist: newest updated_at wins; on a tie,
-- present beats removed; a deleted list or entry is kept as a marker so the
-- deletion reaches other devices (Domain/UserLists.swift ListMerge).

create table public.lists (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  profile_id text not null default 'default' check (char_length(profile_id) between 1 and 64),
  id text not null check (char_length(id) between 1 and 64),
  name text not null check (char_length(name) between 1 and 60),
  symbol text not null default 'list.bullet' check (char_length(symbol) <= 64),
  position double precision not null default 0,
  created_at timestamptz not null,
  is_removed boolean not null default false,
  updated_at timestamptz not null,
  server_updated_at timestamptz not null default clock_timestamp(),
  primary key (user_id, profile_id, id)
);

create table public.list_entries (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  profile_id text not null default 'default' check (char_length(profile_id) between 1 and 64),
  list_id text not null check (char_length(list_id) between 1 and 64),
  media_key text not null check (char_length(media_key) between 1 and 200),
  -- One text key for the pull cursor, which pages on (server_updated_at, key).
  entry_key text generated always as (list_id || '/' || media_key) stored,
  title jsonb not null check (octet_length(title::text) <= 16384),
  position double precision not null default 0,
  added_at timestamptz not null,
  is_removed boolean not null default false,
  updated_at timestamptz not null,
  server_updated_at timestamptz not null default clock_timestamp(),
  primary key (user_id, profile_id, list_id, media_key)
);

create index lists_pull_idx on public.lists (user_id, profile_id, server_updated_at, id);
create index list_entries_pull_idx on public.list_entries (user_id, profile_id, server_updated_at, entry_key);
create trigger lists_touch before insert or update on public.lists
  for each row execute function public.touch_server_updated_at();
create trigger list_entries_touch before insert or update on public.list_entries
  for each row execute function public.touch_server_updated_at();

alter table public.lists enable row level security;
alter table public.list_entries enable row level security;

create policy "own lists: select" on public.lists
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "own lists: insert" on public.lists
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "own lists: update" on public.lists
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "own lists: delete" on public.lists
  for delete to authenticated using ((select auth.uid()) = user_id);

create policy "own list entries: select" on public.list_entries
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "own list entries: insert" on public.list_entries
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "own list entries: update" on public.list_entries
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "own list entries: delete" on public.list_entries
  for delete to authenticated using ((select auth.uid()) = user_id);

revoke all on public.lists, public.list_entries from anon;
grant select, insert, update, delete on public.lists, public.list_entries to authenticated;

-- Upserts a batch of lists and returns the stored row for every id in the batch.
create function public.sync_lists_for(profile text, items jsonb)
returns setof public.lists
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if profile is null or char_length(profile) not between 1 and 64 then
    raise exception 'invalid profile' using errcode = '22023';
  end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) > 500 then
    raise exception 'items must be an array of at most 500 records' using errcode = '22023';
  end if;

  insert into public.lists as e (profile_id, id, name, symbol, position, created_at, is_removed, updated_at)
  select distinct on (i.id)
         profile, i.id, i.name, coalesce(i.symbol, 'list.bullet'), coalesce(i.position, 0), i.created_at,
         coalesce(i.is_removed, false), i.updated_at
  from jsonb_to_recordset(items) as i (
    id text, name text, symbol text, position double precision, created_at timestamptz,
    is_removed boolean, updated_at timestamptz)
  order by i.id, i.updated_at desc
  on conflict (user_id, profile_id, id) do update set
    name = excluded.name,
    symbol = excluded.symbol,
    position = excluded.position,
    created_at = excluded.created_at,
    is_removed = excluded.is_removed,
    updated_at = excluded.updated_at
  where excluded.updated_at > e.updated_at
     or (excluded.updated_at = e.updated_at and e.is_removed and not excluded.is_removed);

  return query
    select l.* from public.lists l
    where l.user_id = auth.uid() and l.profile_id = profile
      and l.id in (select x ->> 'id' from jsonb_array_elements(items) as x);
end;
$$;

-- Same for the titles on them, keyed by (list_id, media_key).
create function public.sync_list_entries_for(profile text, items jsonb)
returns setof public.list_entries
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if profile is null or char_length(profile) not between 1 and 64 then
    raise exception 'invalid profile' using errcode = '22023';
  end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) > 500 then
    raise exception 'items must be an array of at most 500 records' using errcode = '22023';
  end if;

  insert into public.list_entries as e (profile_id, list_id, media_key, title, position, added_at, is_removed, updated_at)
  select distinct on (i.list_id, i.media_key)
         profile, i.list_id, i.media_key, i.title, coalesce(i.position, 0), i.added_at, coalesce(i.is_removed, false), i.updated_at
  from jsonb_to_recordset(items) as i (
    list_id text, media_key text, title jsonb, position double precision, added_at timestamptz,
    is_removed boolean, updated_at timestamptz)
  order by i.list_id, i.media_key, i.updated_at desc
  on conflict (user_id, profile_id, list_id, media_key) do update set
    title = excluded.title,
    position = excluded.position,
    added_at = excluded.added_at,
    is_removed = excluded.is_removed,
    updated_at = excluded.updated_at
  where excluded.updated_at > e.updated_at
     or (excluded.updated_at = e.updated_at and e.is_removed and not excluded.is_removed);

  return query
    select l.* from public.list_entries l
    where l.user_id = auth.uid() and l.profile_id = profile
      and l.entry_key in (select (x ->> 'list_id') || '/' || (x ->> 'media_key') from jsonb_array_elements(items) as x);
end;
$$;

revoke all on function public.sync_lists_for(text, jsonb), public.sync_list_entries_for(text, jsonb) from public, anon;
grant execute on function public.sync_lists_for(text, jsonb), public.sync_list_entries_for(text, jsonb) to authenticated;

-- My List's manual order. Null from older builds, which sort by added_at; an
-- older build's write keeps the order a newer one stored.
alter table public.watchlist_entries add column position double precision;

create or replace function public.sync_watchlist_for(profile text, items jsonb)
returns setof public.watchlist_entries
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if profile is null or char_length(profile) not between 1 and 64 then
    raise exception 'invalid profile' using errcode = '22023';
  end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) > 500 then
    raise exception 'items must be an array of at most 500 records' using errcode = '22023';
  end if;

  insert into public.watchlist_entries as e (profile_id, media_key, title, added_at, is_removed, updated_at, position)
  select distinct on (i.media_key)
         profile, i.media_key, i.title, i.added_at, coalesce(i.is_removed, false), i.updated_at, i.position
  from jsonb_to_recordset(items) as i (
    media_key text, title jsonb, added_at timestamptz, is_removed boolean, updated_at timestamptz, position double precision)
  order by i.media_key, i.updated_at desc
  on conflict (user_id, profile_id, media_key) do update set
    title = excluded.title,
    added_at = excluded.added_at,
    is_removed = excluded.is_removed,
    updated_at = excluded.updated_at,
    position = coalesce(excluded.position, e.position)
  where excluded.updated_at > e.updated_at
     or (excluded.updated_at = e.updated_at and e.is_removed and not excluded.is_removed);

  return query
    select w.* from public.watchlist_entries w
    where w.user_id = auth.uid() and w.profile_id = profile
      and w.media_key in (select x ->> 'media_key' from jsonb_array_elements(items) as x);
end;
$$;

-- Realtime for the new tables, as for the others.
do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['lists', 'list_entries'] loop
      if not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;
