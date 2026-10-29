-- Profiles: several people share one account, each with their own My List and
-- watch progress. Rows from before this migration belong to the 'default'
-- profile, which every account has implicitly.
--
-- The profile list itself syncs like the watchlist: newest updated_at wins,
-- and a removal is kept as a marker so it reaches other devices.

create table public.profiles (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id text not null check (char_length(id) between 1 and 64),
  name text not null check (char_length(name) between 1 and 40),
  symbol text not null default 'person.fill' check (char_length(symbol) <= 64),
  color smallint not null default 0 check (color between 0 and 15),
  is_removed boolean not null default false,
  updated_at timestamptz not null,
  server_updated_at timestamptz not null default clock_timestamp(),
  primary key (user_id, id)
);

create index profiles_pull_idx on public.profiles (user_id, server_updated_at, id);
create trigger profiles_touch before insert or update on public.profiles
  for each row execute function public.touch_server_updated_at();

alter table public.profiles enable row level security;
create policy "own profiles: select" on public.profiles
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "own profiles: insert" on public.profiles
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "own profiles: update" on public.profiles
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "own profiles: delete" on public.profiles
  for delete to authenticated using ((select auth.uid()) = user_id);
revoke all on public.profiles from anon;
grant select, insert, update, delete on public.profiles to authenticated;

-- Scope library rows by profile.
alter table public.watch_progress add column profile_id text not null default 'default'
  check (char_length(profile_id) between 1 and 64);
alter table public.watchlist_entries add column profile_id text not null default 'default'
  check (char_length(profile_id) between 1 and 64);

alter table public.watch_progress drop constraint watch_progress_pkey;
alter table public.watch_progress add primary key (user_id, profile_id, media_key);
alter table public.watchlist_entries drop constraint watchlist_entries_pkey;
alter table public.watchlist_entries add primary key (user_id, profile_id, media_key);

drop index public.watch_progress_pull_idx;
drop index public.watchlist_entries_pull_idx;
create index watch_progress_pull_idx on public.watch_progress (user_id, profile_id, server_updated_at, media_key);
create index watchlist_entries_pull_idx on public.watchlist_entries (user_id, profile_id, server_updated_at, media_key);

-- Profile-aware sync functions. Same merge rules as before.
create function public.sync_progress_for(profile text, items jsonb)
returns setof public.watch_progress
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

  insert into public.watch_progress as e (profile_id, media_key, position, duration, is_completed, updated_at, device_id)
  select distinct on (i.media_key)
         profile, i.media_key, i.position, i.duration, coalesce(i.is_completed, false), i.updated_at, i.device_id
  from jsonb_to_recordset(items) as i (
    media_key text, position double precision, duration double precision,
    is_completed boolean, updated_at timestamptz, device_id text)
  order by i.media_key, i.updated_at desc
  on conflict (user_id, profile_id, media_key) do update set
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
    where p.user_id = auth.uid() and p.profile_id = profile
      and p.media_key in (select x ->> 'media_key' from jsonb_array_elements(items) as x);
end;
$$;

create function public.sync_watchlist_for(profile text, items jsonb)
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

  insert into public.watchlist_entries as e (profile_id, media_key, title, added_at, is_removed, updated_at)
  select distinct on (i.media_key)
         profile, i.media_key, i.title, i.added_at, coalesce(i.is_removed, false), i.updated_at
  from jsonb_to_recordset(items) as i (
    media_key text, title jsonb, added_at timestamptz, is_removed boolean, updated_at timestamptz)
  order by i.media_key, i.updated_at desc
  on conflict (user_id, profile_id, media_key) do update set
    title = excluded.title,
    added_at = excluded.added_at,
    is_removed = excluded.is_removed,
    updated_at = excluded.updated_at
  where excluded.updated_at > e.updated_at
     or (excluded.updated_at = e.updated_at and e.is_removed and not excluded.is_removed);

  return query
    select w.* from public.watchlist_entries w
    where w.user_id = auth.uid() and w.profile_id = profile
      and w.media_key in (select x ->> 'media_key' from jsonb_array_elements(items) as x);
end;
$$;

-- Older app builds call these; they now mean the default profile.
create or replace function public.sync_progress(items jsonb)
returns setof public.watch_progress
language sql
security invoker
set search_path = ''
as $$ select * from public.sync_progress_for('default', items) $$;

create or replace function public.sync_watchlist(items jsonb)
returns setof public.watchlist_entries
language sql
security invoker
set search_path = ''
as $$ select * from public.sync_watchlist_for('default', items) $$;

-- Newest updated_at wins; on a tie, present beats removed.
create function public.sync_profiles(items jsonb)
returns setof public.profiles
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) > 50 then
    raise exception 'items must be an array of at most 50 profiles' using errcode = '22023';
  end if;

  insert into public.profiles as e (id, name, symbol, color, is_removed, updated_at)
  select distinct on (i.id)
         i.id, i.name, coalesce(i.symbol, 'person.fill'), coalesce(i.color, 0), coalesce(i.is_removed, false), i.updated_at
  from jsonb_to_recordset(items) as i (
    id text, name text, symbol text, color smallint, is_removed boolean, updated_at timestamptz)
  order by i.id, i.updated_at desc
  on conflict (user_id, id) do update set
    name = excluded.name,
    symbol = excluded.symbol,
    color = excluded.color,
    is_removed = excluded.is_removed,
    updated_at = excluded.updated_at
  where excluded.updated_at > e.updated_at
     or (excluded.updated_at = e.updated_at and e.is_removed and not excluded.is_removed);

  return query
    select p.* from public.profiles p
    where p.user_id = auth.uid()
      and p.id in (select x ->> 'id' from jsonb_array_elements(items) as x);
end;
$$;

revoke all on function public.sync_progress_for(text, jsonb), public.sync_watchlist_for(text, jsonb),
  public.sync_profiles(jsonb) from public, anon;
grant execute on function public.sync_progress_for(text, jsonb), public.sync_watchlist_for(text, jsonb),
  public.sync_profiles(jsonb) to authenticated;
