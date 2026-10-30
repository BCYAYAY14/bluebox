-- Realtime: private channels only. Remote control (bluebox-remote:<user id>)
-- and the sync change signal (bluebox-sync:<user id>) are joined with
-- config.private = true, so Realtime checks these policies on realtime.messages:
-- a signed-in user may listen on, and broadcast to, their own topics and no
-- others. Turn off public channel access (Realtime › Settings › "Allow public
-- access") so nobody can join without them.
--
-- Safe to run more than once: automatic setup runs it on every set-up.

drop policy if exists "bluebox: read own topics" on realtime.messages;
create policy "bluebox: read own topics" on realtime.messages
  for select to authenticated
  using (realtime.topic() in ('bluebox-remote:' || (select auth.uid())::text,
                              'bluebox-sync:' || (select auth.uid())::text));

drop policy if exists "bluebox: broadcast to own remote topic" on realtime.messages;
create policy "bluebox: broadcast to own remote topic" on realtime.messages
  for insert to authenticated
  with check (realtime.messages.extension = 'broadcast'
              and realtime.topic() = 'bluebox-remote:' || (select auth.uid())::text);

-- Lets Settings › Account › Check Setup see this file has run (it can't read policies).
create or replace function public.bluebox_realtime_private() returns boolean
language sql stable as $$ select true $$;
grant execute on function public.bluebox_realtime_private() to anon, authenticated;
