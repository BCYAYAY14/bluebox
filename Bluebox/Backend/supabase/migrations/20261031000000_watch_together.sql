-- Watch Together rooms (bluebox-together:<join code>): a private broadcast
-- topic per room, named by its eight-character code. Unlike the remote and
-- sync topics, a room isn't one account's: anyone signed in to this project
-- may listen and broadcast on a room's topic, including guests from another
-- person's Bluebox, who sign in anonymously (Authentication › Sign In /
-- Providers › "Allow anonymous sign-ins"). The code is the key, so it is long
-- enough not to be guessed, and nothing sent in a room is stored.
--
-- Safe to run more than once: automatic setup runs it on every set-up.

drop policy if exists "bluebox: read watch together rooms" on realtime.messages;
create policy "bluebox: read watch together rooms" on realtime.messages
  for select to authenticated
  using (realtime.messages.extension = 'broadcast'
         and realtime.topic() ~ '^bluebox-together:[a-z0-9]{8}$');

drop policy if exists "bluebox: broadcast to watch together rooms" on realtime.messages;
create policy "bluebox: broadcast to watch together rooms" on realtime.messages
  for insert to authenticated
  with check (realtime.messages.extension = 'broadcast'
              and realtime.topic() ~ '^bluebox-together:[a-z0-9]{8}$');
