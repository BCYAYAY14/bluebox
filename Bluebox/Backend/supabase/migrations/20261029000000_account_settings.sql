-- Account settings: API keys, add-ons and app settings, so a new device signs
-- in and has them. One row per (user, key); the value is whatever the app
-- stores under that key (JSON text, or a key's plain text).
--
-- These are the account's own secrets in its own project: RLS keeps them to
-- the signed-in user, and the anon role can't read the table at all.
--
-- Syncs like the watchlist: newest updated_at wins, and a removal (a key
-- cleared in Settings) is kept as a marker so it reaches other devices.

create table public.account_settings (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  key text not null check (char_length(key) between 1 and 200),
  value text check (value is null or octet_length(value) <= 262144),
  is_removed boolean not null default false,
  updated_at timestamptz not null,
  server_updated_at timestamptz not null default clock_timestamp(),
  primary key (user_id, key)
);

create index account_settings_pull_idx on public.account_settings (user_id, server_updated_at, key);
create trigger account_settings_touch before insert or update on public.account_settings
  for each row execute function public.touch_server_updated_at();

alter table public.account_settings enable row level security;
create policy "own settings: select" on public.account_settings
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "own settings: insert" on public.account_settings
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "own settings: update" on public.account_settings
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "own settings: delete" on public.account_settings
  for delete to authenticated using ((select auth.uid()) = user_id);
revoke all on public.account_settings from anon;
grant select, insert, update, delete on public.account_settings to authenticated;

-- Upserts a batch of settings and returns the stored row for every key in the
-- batch. Incoming wins when its updated_at is newer (matching SettingsMerge).
create function public.sync_settings(items jsonb)
returns setof public.account_settings
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) > 200 then
    raise exception 'items must be an array of at most 200 settings' using errcode = '22023';
  end if;

  insert into public.account_settings as e (key, value, is_removed, updated_at)
  select distinct on (i.key)
         i.key, case when coalesce(i.is_removed, false) then null else i.value end,
         coalesce(i.is_removed, false), i.updated_at
  from jsonb_to_recordset(items) as i (key text, value text, is_removed boolean, updated_at timestamptz)
  order by i.key, i.updated_at desc
  on conflict (user_id, key) do update set
    value = excluded.value,
    is_removed = excluded.is_removed,
    updated_at = excluded.updated_at
  where excluded.updated_at > e.updated_at;

  return query
    select s.* from public.account_settings s
    where s.user_id = auth.uid()
      and s.key in (select x ->> 'key' from jsonb_array_elements(items) as x);
end;
$$;

revoke all on function public.sync_settings(jsonb) from public, anon;
grant execute on function public.sync_settings(jsonb) to authenticated;

-- Realtime: signed-in devices hear when their rows change, so another
-- device's change shows up in a second or two (RLS still decides who hears
-- what). Skipped where there's no Realtime, like a plain Postgres test database.
do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['watch_progress', 'watchlist_entries', 'profiles', 'account_settings'] loop
      if not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;
