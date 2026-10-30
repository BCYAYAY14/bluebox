-- Minimal stand-in for the pieces of Supabase the migration relies on, so it
-- can be tested on plain Postgres (no Docker). Not used in production.
create role anon nologin;
create role authenticated nologin;
create schema auth;
create table auth.users (id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
grant usage on schema auth to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;
grant usage on schema public to anon, authenticated;
-- Supabase creates this publication for Realtime; the settings migration adds the sync tables to it.
create publication supabase_realtime;
-- Realtime Authorization: Realtime checks a private channel's join and
-- broadcasts by reading and inserting realtime.messages as the user, with the
-- channel's topic in realtime.topic.
create schema realtime;
create table realtime.messages (
  id bigserial primary key,
  topic text not null,
  extension text not null,
  payload jsonb,
  event text,
  private boolean default false
);
alter table realtime.messages enable row level security;
create function realtime.topic() returns text language sql stable as $$
  select nullif(current_setting('realtime.topic', true), '')
$$;
grant usage on schema realtime to anon, authenticated;
grant select, insert on realtime.messages to anon, authenticated;
grant usage on sequence realtime.messages_id_seq to anon, authenticated;
grant execute on function realtime.topic() to anon, authenticated;
