-- Behaviour tests for the library sync migration. Run with tools/test-supabase-sql.sh.
\set ON_ERROR_STOP on
\set a '''aaaaaaaa-0000-0000-0000-000000000001'''
\set b '''bbbbbbbb-0000-0000-0000-000000000002'''
insert into auth.users values (:a), (:b);

create function pg_temp.check(ok boolean, label text) returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'FAILED: %', label; end if;
  raise notice 'ok - %', label;
end $$;

-- Act as user A.
set role authenticated;
select set_config('request.jwt.claim.sub', :a, false);

select count(*) from public.sync_progress('[{"media_key":"tmdb:movie:1","position":600,"duration":3600,"is_completed":false,"updated_at":"2026-01-01T00:00:10.123Z","device_id":"d1"}]');
select pg_temp.check((select position = 600 and user_id = :a::uuid from public.watch_progress where media_key = 'tmdb:movie:1'), 'insert owned by caller');

-- Stale write loses, but the current row comes back.
select pg_temp.check((select position = 600 from public.sync_progress('[{"media_key":"tmdb:movie:1","position":900,"duration":3600,"is_completed":false,"updated_at":"2026-01-01T00:00:05Z","device_id":"d2"}]')), 'stale write rejected, winner returned');

-- Newer rewind wins.
select count(*) from public.sync_progress('[{"media_key":"tmdb:movie:1","position":300,"duration":3600,"is_completed":false,"updated_at":"2026-01-01T00:00:20Z","device_id":"d2"}]');
select pg_temp.check((select position = 300 from public.watch_progress where media_key = 'tmdb:movie:1'), 'newer write wins');

-- Ties: completed beats not completed, then larger position, then larger device.
select count(*) from public.sync_progress('[{"media_key":"tmdb:movie:1","position":100,"duration":3600,"is_completed":true,"updated_at":"2026-01-01T00:00:20Z","device_id":"a"}]');
select pg_temp.check((select is_completed from public.watch_progress where media_key = 'tmdb:movie:1'), 'tie: completed wins');
select count(*) from public.sync_progress('[{"media_key":"tmdb:movie:1","position":200,"duration":3600,"is_completed":true,"updated_at":"2026-01-01T00:00:20Z","device_id":"a"}]');
select pg_temp.check((select position = 200 from public.watch_progress where media_key = 'tmdb:movie:1'), 'tie: larger position wins');
select count(*) from public.sync_progress('[{"media_key":"tmdb:movie:1","position":200,"duration":3600,"is_completed":true,"updated_at":"2026-01-01T00:00:20Z","device_id":"z"}]');
select pg_temp.check((select device_id = 'z' from public.watch_progress where media_key = 'tmdb:movie:1'), 'tie: larger device wins');

-- Losing writes don't bump server_updated_at.
select server_updated_at as before from public.watch_progress where media_key = 'tmdb:movie:1' \gset
select count(*) from public.sync_progress('[{"media_key":"tmdb:movie:1","position":1,"duration":3600,"is_completed":false,"updated_at":"2020-01-01T00:00:00Z"}]');
select pg_temp.check((select server_updated_at = :'before'::timestamptz from public.watch_progress where media_key = 'tmdb:movie:1'), 'losing write leaves cursor alone');

-- Duplicate keys in one batch: newest wins, no "affect row a second time" error.
select count(*) from public.sync_progress('[{"media_key":"tmdb:movie:2","position":5,"updated_at":"2026-01-01T00:00:01Z"},{"media_key":"tmdb:movie:2","position":50,"updated_at":"2026-01-01T00:00:02Z"}]');
select pg_temp.check((select position = 50 from public.watch_progress where media_key = 'tmdb:movie:2'), 'duplicate keys in batch');

-- Watchlist: newer wins; tie → present beats removed.
select count(*) from public.sync_watchlist('[{"media_key":"tmdb:tv:9","title":{"name":"Nine"},"added_at":"2026-01-01T00:00:00Z","is_removed":false,"updated_at":"2026-01-01T00:00:00Z"}]');
select count(*) from public.sync_watchlist('[{"media_key":"tmdb:tv:9","title":{"name":"Nine"},"added_at":"2026-01-01T00:00:00Z","is_removed":true,"updated_at":"2026-01-02T00:00:00Z"}]');
select pg_temp.check((select is_removed from public.watchlist_entries where media_key = 'tmdb:tv:9'), 'watchlist removal syncs');
select count(*) from public.sync_watchlist('[{"media_key":"tmdb:tv:9","title":{"name":"Nine"},"added_at":"2026-01-02T00:00:00Z","is_removed":false,"updated_at":"2026-01-02T00:00:00Z"}]');
select pg_temp.check((select not is_removed from public.watchlist_entries where media_key = 'tmdb:tv:9'), 'watchlist tie: present wins');

-- Client can't write another user's rows.
select pg_temp.check(not exists (select 1 from public.watch_progress where user_id <> :a::uuid), 'only own rows');
do $$ begin
  insert into public.watch_progress (user_id, media_key, position, updated_at)
  values ('bbbbbbbb-0000-0000-0000-000000000002', 'x', 1, now());
  raise exception 'FAILED: insert for other user allowed';
exception when insufficient_privilege then raise notice 'ok - RLS blocks writing as another user';
end $$;

-- User B sees nothing of A's.
select set_config('request.jwt.claim.sub', :b, false);
select pg_temp.check((select count(*) = 0 from public.watch_progress), 'user B sees none of A''s progress');
select pg_temp.check((select count(*) = 0 from public.sync_progress('[{"media_key":"tmdb:movie:1","position":1,"updated_at":"2030-01-01T00:00:00Z"}]') where position <> 1), 'B writes own row only');
select set_config('request.jwt.claim.sub', :a, false);
select pg_temp.check((select position = 200 from public.watch_progress where media_key = 'tmdb:movie:1'), 'A unaffected by B');

-- Profiles: library rows are separate per profile; old functions mean 'default'.
select pg_temp.check((select bool_and(profile_id = 'default') from public.watch_progress), 'existing rows are in the default profile');
select count(*) from public.sync_progress_for('kids', '[{"media_key":"tmdb:movie:1","position":42,"updated_at":"2026-02-01T00:00:00Z"}]');
select pg_temp.check((select position = 200 from public.watch_progress where media_key = 'tmdb:movie:1' and profile_id = 'default'), 'default profile untouched by kids');
select pg_temp.check((select position = 42 from public.watch_progress where media_key = 'tmdb:movie:1' and profile_id = 'kids'), 'kids profile has its own row');
select pg_temp.check((select count(*) = 1 from public.sync_watchlist_for('kids', '[{"media_key":"tmdb:tv:9","title":{"name":"Nine"},"added_at":"2026-01-01T00:00:00Z","is_removed":false,"updated_at":"2026-03-01T00:00:00Z"}]')), 'watchlist per profile returns only that profile');
select pg_temp.check((select count(*) = 2 from public.watchlist_entries where media_key = 'tmdb:tv:9'), 'same title on two profiles');

select count(*) from public.sync_profiles('[{"id":"kids","name":"Kids","symbol":"star.fill","color":3,"updated_at":"2026-01-01T00:00:00Z"}]');
select count(*) from public.sync_profiles('[{"id":"kids","name":"Old name","updated_at":"2025-01-01T00:00:00Z"}]');
select pg_temp.check((select name = 'Kids' and color = 3 from public.profiles where id = 'kids'), 'stale profile rename loses');
select count(*) from public.sync_profiles('[{"id":"kids","name":"Kids","is_removed":true,"updated_at":"2026-01-02T00:00:00Z"}]');
select pg_temp.check((select is_removed from public.profiles where id = 'kids'), 'profile removal syncs');
do $$ begin
  perform public.sync_progress_for('', '[]');
  raise exception 'FAILED: empty profile accepted';
exception when sqlstate '22023' then raise notice 'ok - empty profile id rejected';
end $$;
select set_config('request.jwt.claim.sub', :b, false);
select pg_temp.check((select count(*) = 0 from public.profiles), 'user B sees none of A''s profiles');
select set_config('request.jwt.claim.sub', :a, false);

-- Account settings: newest wins, removals sync, each user sees only their own.
select count(*) from public.sync_settings('[{"key":"secret.tmdb.credential","value":"k1","is_removed":false,"updated_at":"2026-01-01T00:00:10Z"}]');
select pg_temp.check((select value = 'k1' and user_id = :a::uuid from public.account_settings where key = 'secret.tmdb.credential'), 'setting stored for caller');
select pg_temp.check((select value = 'k1' from public.sync_settings('[{"key":"secret.tmdb.credential","value":"old","is_removed":false,"updated_at":"1970-01-01T00:00:00Z"}]')), 'older setting loses, winner returned');
select pg_temp.check((select value = 'k1' from public.sync_settings('[{"key":"secret.tmdb.credential","value":"tie","is_removed":false,"updated_at":"2026-01-01T00:00:10Z"}]')), 'tie keeps the stored setting');
select count(*) from public.sync_settings('[{"key":"secret.tmdb.credential","value":"ignored","is_removed":true,"updated_at":"2026-01-01T00:00:20Z"}]');
select pg_temp.check((select is_removed and value is null from public.account_settings where key = 'secret.tmdb.credential'), 'removal clears the value');
do $$ begin
  perform public.sync_settings((select jsonb_agg(jsonb_build_object('key', 'k' || g, 'value', 'v', 'updated_at', '2026-01-01T00:00:00Z')) from generate_series(1, 201) g));
  raise exception 'FAILED: oversized settings batch accepted';
exception when sqlstate '22023' then raise notice 'ok - settings batch limit';
end $$;
select set_config('request.jwt.claim.sub', :b, false);
select pg_temp.check((select count(*) = 0 from public.account_settings), 'user B sees none of A''s settings');
select set_config('request.jwt.claim.sub', :a, false);

-- Lists: per profile, newest wins, tie → present beats removed, deletions sync.
select count(*) from public.sync_lists_for('default', '[{"id":"L1","name":"Halloween","symbol":"moon.fill","position":0,"created_at":"2026-10-01T00:00:00Z","is_removed":false,"updated_at":"2026-10-01T00:00:00Z"}]');
select pg_temp.check((select name = 'Halloween' and symbol = 'moon.fill' and user_id = :a::uuid from public.lists where id = 'L1'), 'list stored for caller');
select pg_temp.check((select name = 'Halloween' from public.sync_lists_for('default', '[{"id":"L1","name":"Old","created_at":"2026-10-01T00:00:00Z","updated_at":"2026-09-01T00:00:00Z"}]')), 'stale list rename loses, winner returned');
select count(*) from public.sync_lists_for('default', '[{"id":"L1","name":"Halloween","is_removed":true,"created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-02T00:00:00Z"}]');
select pg_temp.check((select is_removed from public.lists where id = 'L1'), 'list deletion syncs');
select count(*) from public.sync_lists_for('default', '[{"id":"L1","name":"Halloween","is_removed":false,"created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-02T00:00:00Z"}]');
select pg_temp.check((select not is_removed from public.lists where id = 'L1'), 'list tie: present wins');
select pg_temp.check((select count(*) = 0 from public.sync_lists_for('kids', '[]')), 'empty batch is fine');
select pg_temp.check((select count(*) = 0 from public.lists where profile_id = 'kids'), 'lists are per profile');

select count(*) from public.sync_list_entries_for('default', '[{"list_id":"L1","media_key":"tmdb:movie:1","title":{"name":"One"},"position":0,"added_at":"2026-10-01T00:00:00Z","is_removed":false,"updated_at":"2026-10-01T00:00:00Z"},{"list_id":"L1","media_key":"tmdb:movie:2","title":{"name":"Two"},"position":1,"added_at":"2026-10-01T00:00:00Z","is_removed":false,"updated_at":"2026-10-01T00:00:00Z"}]');
select pg_temp.check((select entry_key = 'L1/tmdb:movie:1' from public.list_entries where media_key = 'tmdb:movie:1'), 'entry key generated');
select pg_temp.check((select count(*) = 1 from public.sync_list_entries_for('default', '[{"list_id":"L1","media_key":"tmdb:movie:2","title":{"name":"Two"},"position":0,"added_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-03T00:00:00Z"}]') where position = 0), 'reorder returns only that entry');
select pg_temp.check((select position = 1 from public.sync_list_entries_for('default', '[{"list_id":"L1","media_key":"tmdb:movie:2","title":{"name":"Two"},"position":1,"added_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-02T00:00:00Z"}]')) is not true, 'stale reorder loses');
select count(*) from public.sync_list_entries_for('default', '[{"list_id":"L1","media_key":"tmdb:movie:1","title":{"name":"One"},"added_at":"2026-10-01T00:00:00Z","is_removed":true,"updated_at":"2026-10-04T00:00:00Z"}]');
select pg_temp.check((select is_removed from public.list_entries where media_key = 'tmdb:movie:1'), 'entry removal syncs');
select pg_temp.check((select count(*) = 1 from public.sync_list_entries_for('default', '[{"list_id":"L1","media_key":"tmdb:movie:1","title":{"name":"One"},"added_at":"2026-10-01T00:00:00Z","is_removed":true,"updated_at":"2026-10-04T00:00:00Z"},{"list_id":"L1","media_key":"tmdb:movie:1","title":{"name":"One"},"added_at":"2026-10-01T00:00:00Z","is_removed":false,"updated_at":"2026-10-05T00:00:00Z"}]') where not is_removed), 'duplicate entries in batch: newest wins');
do $$ begin
  perform public.sync_list_entries_for('', '[]');
  raise exception 'FAILED: empty profile accepted';
exception when sqlstate '22023' then raise notice 'ok - list entries reject an empty profile';
end $$;

-- My List's manual order: stored, and kept when an older build writes without one.
select count(*) from public.sync_watchlist_for('default', '[{"media_key":"tmdb:tv:9","title":{"name":"Nine"},"added_at":"2026-01-02T00:00:00Z","is_removed":false,"updated_at":"2026-04-01T00:00:00Z","position":3}]');
select pg_temp.check((select position = 3 from public.watchlist_entries where media_key = 'tmdb:tv:9' and profile_id = 'default'), 'watchlist position stored');
select count(*) from public.sync_watchlist('[{"media_key":"tmdb:tv:9","title":{"name":"Nine"},"added_at":"2026-01-02T00:00:00Z","is_removed":false,"updated_at":"2026-05-01T00:00:00Z"}]');
select pg_temp.check((select position = 3 and updated_at = '2026-05-01T00:00:00Z'::timestamptz from public.watchlist_entries where media_key = 'tmdb:tv:9' and profile_id = 'default'), 'older build keeps the order');

select set_config('request.jwt.claim.sub', :b, false);
select pg_temp.check((select count(*) = 0 from public.lists) and (select count(*) = 0 from public.list_entries), 'user B sees none of A''s lists');
select set_config('request.jwt.claim.sub', :a, false);
reset role;
select pg_temp.check((select count(*) = 6 from pg_publication_tables where pubname = 'supabase_realtime'), 'sync tables publish to Realtime');
set role authenticated;

-- Anonymous callers get nothing.
reset role;
set role anon;
do $$ begin
  perform public.sync_progress('[]');
  raise exception 'FAILED: anon can call sync_progress';
exception when insufficient_privilege then raise notice 'ok - anon cannot call sync functions';
end $$;
do $$ begin
  perform 1 from public.watch_progress;
  raise exception 'FAILED: anon can read progress';
exception when insufficient_privilege then raise notice 'ok - anon cannot read tables';
end $$;
do $$ begin
  perform 1 from public.account_settings;
  raise exception 'FAILED: anon can read settings';
exception when insufficient_privilege then raise notice 'ok - anon cannot read settings';
end $$;
do $$ begin
  perform 1 from public.lists;
  raise exception 'FAILED: anon can read lists';
exception when insufficient_privilege then raise notice 'ok - anon cannot read lists';
end $$;
do $$ begin
  perform public.sync_lists_for('default', '[]');
  raise exception 'FAILED: anon can call sync_lists_for';
exception when insufficient_privilege then raise notice 'ok - anon cannot call list sync';
end $$;
reset role;
-- Realtime Authorization (security review BB-03): own topics only.
insert into realtime.messages (topic, extension, private) values
  ('bluebox-remote:aaaaaaaa-0000-0000-0000-000000000001', 'broadcast', true),
  ('bluebox-remote:bbbbbbbb-0000-0000-0000-000000000002', 'broadcast', true),
  ('bluebox-sync:aaaaaaaa-0000-0000-0000-000000000001', 'presence', true);
set role authenticated;
select set_config('request.jwt.claim.sub', :a, false);
select set_config('realtime.topic', 'bluebox-remote:aaaaaaaa-0000-0000-0000-000000000001', false);
select pg_temp.check((select count(*) > 0 from realtime.messages), 'realtime: A can join own remote topic');
insert into realtime.messages (topic, extension, private) values ('bluebox-remote:aaaaaaaa-0000-0000-0000-000000000001', 'broadcast', true);
select pg_temp.check(true, 'realtime: A can broadcast on own remote topic');
select set_config('realtime.topic', 'bluebox-sync:aaaaaaaa-0000-0000-0000-000000000001', false);
select pg_temp.check((select count(*) > 0 from realtime.messages), 'realtime: A can join own sync topic');
do $$ begin
  insert into realtime.messages (topic, extension, private) values ('bluebox-sync:aaaaaaaa-0000-0000-0000-000000000001', 'broadcast', true);
  raise exception 'FAILED: A can broadcast on the sync topic';
exception when insufficient_privilege then raise notice 'ok - realtime: nobody broadcasts on a sync topic';
end $$;
select set_config('realtime.topic', 'bluebox-remote:bbbbbbbb-0000-0000-0000-000000000002', false);
select pg_temp.check((select count(*) = 0 from realtime.messages), 'realtime: A cannot join B''s remote topic');
do $$ begin
  insert into realtime.messages (topic, extension, private) values ('bluebox-remote:bbbbbbbb-0000-0000-0000-000000000002', 'broadcast', true);
  raise exception 'FAILED: A can broadcast on B''s topic';
exception when insufficient_privilege then raise notice 'ok - realtime: A cannot broadcast to B';
end $$;
reset role;
set role anon;
select set_config('request.jwt.claim.sub', '', false);
select set_config('realtime.topic', 'bluebox-remote:aaaaaaaa-0000-0000-0000-000000000001', false);
select pg_temp.check((select count(*) = 0 from realtime.messages), 'realtime: signed-out clients see nothing');
select pg_temp.check(public.bluebox_realtime_private(), 'realtime: setup marker callable by anon');
reset role;
\echo ALL SQL TESTS PASSED
