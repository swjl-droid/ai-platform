-- Separation test, prj02 (platform plan condition 3, Hub rows 211 and 213; story prj02-R1 US-1):
-- two families join through their own links, with noisy real-world input (names with emoji and
-- spaces, codes typed in capitals or forwarded with spaces). An adult of family B sees, changes
-- and adds nothing of family A; an account that has not joined sees nothing; anon and
-- authenticated reach nothing. Decision Hub row 249: the bot role only ever names a Telegram
-- account, never a person or family. Runs inside a transaction that is rolled back.
begin;

-- The owner creates two families, each with a first admin link.
do $$
declare a jsonb; b jsonb;
begin
  a := app_prj02.create_family(' Tan family ', 'sg', 48);
  b := app_prj02.create_family('Lim household', 'SG', 48);
  perform set_config('test.family_a', a ->> 'family_id', true);
  perform set_config('test.code_a', a ->> 'code', true);
  perform set_config('test.family_b', b ->> 'family_id', true);
  perform set_config('test.code_b', b ->> 'code', true);
end $$;

set local role app_prj02_bot;

-- Before anyone joins: no context, nothing visible.
do $$
declare n int;
begin
  select count(*) into n from app_prj02.families;
  if n <> 0 then raise exception 'a request without context sees % families', n; end if;
end $$;

-- Family A's admin opens the link (forwarded, in capitals, with spaces) and agrees.
do $$
declare r jsonb; n int; v_code text := current_setting('test.code_a');
begin
  r := app_prj02.preview_invite('  ' || upper(left(v_code, 16)) || ' ' || upper(substr(v_code, 17)) || E'\n');
  if (r ->> 'ok')::boolean is not true or r ->> 'family_name' is distinct from 'Tan family' then
    raise exception 'noisy code not recognised: %', r;
  end if;
  r := app_prj02.accept_invite(upper(v_code), 'telegram', ' 7123456789 ', E'  Wei Ling \U0001F338\t ', 'v1');
  if (r ->> 'ok')::boolean is not true then raise exception 'family A admin could not join: %', r; end if;
  perform set_config('test.person_a', r ->> 'person_id', true);
  -- The link is now used up, for anyone.
  r := app_prj02.accept_invite(v_code, 'telegram', '5550001111', 'Someone else', 'v1');
  if r ->> 'reason' is distinct from 'used' then raise exception 'a used link joined someone: %', r; end if;
  -- Context: A's admin sees their family only, with their consent recorded.
  r := app_prj02.begin_request('telegram', '7123456789');
  if r ->> 'notice_version' is distinct from 'v1' or (r ->> 'is_admin')::boolean is not true then
    raise exception 'context wrong: %', r;
  end if;
  select count(*) into n from app_prj02.people where display_name = E'Wei Ling \U0001F338';
  if n <> 1 then raise exception 'display name not cleaned (control characters, spaces)'; end if;
  -- A invites a second adult; that adult joins.
  r := app_prj02.create_invite(48);
  perform set_config('test.code_a2', r ->> 'code', true);
  r := app_prj02.accept_invite(current_setting('test.code_a2'), 'telegram', '5550001111', 'Ah Hock', 'v1');
  if (r ->> 'ok')::boolean is not true then raise exception 'second adult of A could not join: %', r; end if;
  -- A second adult who is not admin cannot invite.
  r := app_prj02.create_invite(48);
  if r ->> 'reason' is distinct from 'not_admin' then raise exception 'a non-admin adult created an invite: %', r; end if;
  -- Back to A's admin: one more link, left open for the test below.
  perform app_prj02.begin_request('telegram', '7123456789');
  r := app_prj02.create_invite(24);
  perform set_config('test.code_a3', r ->> 'code', true);
  select count(*) into n from app_prj02.people;
  if n <> 2 then raise exception 'A sees % people, expected 2', n; end if;
end $$;

-- Family B's admin joins with B's link.
do $$
declare r jsonb;
begin
  r := app_prj02.accept_invite(current_setting('test.code_b'), 'telegram', '6200000001', 'Mdm Lim 林', 'v1');
  if (r ->> 'ok')::boolean is not true then raise exception 'family B admin could not join: %', r; end if;
  if r ->> 'family_id' is distinct from current_setting('test.family_b') then raise exception 'B joined the wrong family'; end if;
  -- An account already in a family cannot join another one.
  r := app_prj02.accept_invite(current_setting('test.code_a3'), 'telegram', '6200000001', 'Mdm Lim', 'v1');
  if r ->> 'reason' is distinct from 'already_member' then raise exception 'B joined family A as well: %', r; end if;
end $$;

-- B, in their own request, sees nothing of A and cannot change it.
do $$
declare
  v_family_a uuid := current_setting('test.family_a')::uuid;
  v_person_a uuid := current_setting('test.person_a')::uuid;
  n int;
  blocked boolean;
  r jsonb;
begin
  perform app_prj02.begin_request('telegram', '6200000001');
  select count(*) into n from app_prj02.families where id = v_family_a;
  if n <> 0 then raise exception 'B sees family A'; end if;
  select count(*) into n from app_prj02.people where family_id = v_family_a;
  if n <> 0 then raise exception 'B sees % people of family A', n; end if;
  select count(*) into n from app_prj02.contacts where family_id = v_family_a;
  if n <> 0 then raise exception 'B sees family A''s Telegram accounts'; end if;
  select count(*) into n from app_prj02.consents where family_id = v_family_a;
  if n <> 0 then raise exception 'B sees family A''s consents'; end if;
  select count(*) into n from app_prj02.invites where family_id = v_family_a;
  if n <> 0 then raise exception 'B sees family A''s invites'; end if;
  select count(*) into n from app_prj02.people;
  if n <> 1 then raise exception 'B sees % people, expected only themselves', n; end if;

  -- No direct writes at all: every change goes through the functions.
  blocked := false;
  begin
    insert into app_prj02.people (family_id, display_name) values (v_family_a, 'planted');
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'B added a person to family A'; end if;
  blocked := false;
  begin
    update app_prj02.people set display_name = 'taken over' where id = v_person_a;
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'B could update people'; end if;
  blocked := false;
  begin
    delete from app_prj02.contacts where family_id = v_family_a;
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'B could delete contacts'; end if;
  -- B cannot write the request context to pose as A.
  blocked := false;
  begin
    insert into app_prj02.request_ctx (xact, family_id, person_id)
      values (pg_current_xact_id(), v_family_a, v_person_a);
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'B wrote a request context for A'; end if;
  -- B's invites are for B's family only.
  r := app_prj02.create_invite(48);
  select count(*) into n from app_prj02.invites
   where family_id = current_setting('test.family_b')::uuid and used_at is null;
  if n <> 1 then raise exception 'B''s invite not in B''s family'; end if;
  -- B cannot forget A, create a family, or read core.
  blocked := false;
  begin
    perform app_prj02.forget(v_person_a);
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'B could call forget() for A'; end if;
  blocked := false;
  begin
    perform app_prj02.create_family('planted', 'SG', 48);
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'the bot role could create a family'; end if;
  blocked := false;
  begin
    perform count(*) from core.audit_log;
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'the bot role could read core.audit_log'; end if;
end $$;

-- Accounts that have not joined see nothing, even right after a member's request in the same
-- transaction (planted wrong-account test, Hub row 249).
do $$
declare r jsonb; n int;
begin
  perform app_prj02.begin_request('telegram', '7123456789');
  r := app_prj02.begin_request('telegram', '999000111');
  if r is not null then raise exception 'unknown account got a context: %', r; end if;
  select count(*) into n from app_prj02.families;
  if n <> 0 then raise exception 'unknown account sees % families', n; end if;
  select count(*) into n from app_prj02.people;
  if n <> 0 then raise exception 'unknown account sees % people', n; end if;
  -- A group chat id (negative), an empty id and an injection attempt are unknown too.
  if app_prj02.begin_request('telegram', '-1001234567890') is not null
     or app_prj02.begin_request('telegram', '') is not null
     or app_prj02.begin_request('telegram', $q$7123456789' or '1'='1$q$) is not null
     or app_prj02.begin_request('whatsapp', '7123456789') is not null then
    raise exception 'a malformed account got a context';
  end if;
  -- Join links that are unknown or expired do nothing.
  r := app_prj02.preview_invite('not-a-real-code');
  if r ->> 'reason' is distinct from 'unknown' then raise exception 'unknown code accepted: %', r; end if;
end $$;

reset role;
update app_prj02.invites set expires_at = now() - interval '1 minute'
 where code_hash = app_prj02.code_hash(current_setting('test.code_a3'));
set local role app_prj02_bot;
do $$
declare r jsonb;
begin
  r := app_prj02.accept_invite(current_setting('test.code_a3'), 'telegram', '8800000002', 'Late uncle', 'v1');
  if r ->> 'reason' is distinct from 'expired' then raise exception 'an expired link joined someone: %', r; end if;
end $$;
reset role;

-- Calendar changes (prj02-R1 US-2): a change is written only after the yes of the adult who asked;
-- nobody else, in the family or outside it, can decide it, see it or record its result.
select app_prj02.set_calendar(current_setting('test.family_a')::uuid, 'tanfamily0123@group.calendar.google.com');
select app_prj02.set_calendar(current_setting('test.family_b')::uuid, ' limhousehold@group.calendar.google.com ');
set local role app_prj02_bot;
do $$
declare c uuid; r jsonb; n int; blocked boolean;
begin
  -- A's admin asks for a change: it waits, logged.
  perform app_prj02.begin_request('telegram', '7123456789');
  c := app_prj02.propose_change('add', null,
    '{"title":"Ethan swim 🏊 (bring goggles!!)","start":"2026-11-28T15:00:00+08:00","end":"2026-11-28T16:00:00+08:00"}', 30);
  perform set_config('test.change_a', c::text, true);
  select count(*) into n from app_prj02.calendar_changes where id = c and status = 'proposed';
  if n <> 1 then raise exception 'proposed change not logged'; end if;
  select count(*) into n from app_prj02.calendars;
  if n <> 1 then raise exception 'A sees % calendars, expected their own 1', n; end if;
  -- The other adult of A cannot say yes for them.
  perform app_prj02.begin_request('telegram', '5550001111');
  r := app_prj02.decide_change(c, true);
  if r ->> 'reason' is distinct from 'not_yours' then raise exception 'another adult decided the change: %', r; end if;
  -- B sees nothing of it and cannot decide or record it.
  perform app_prj02.begin_request('telegram', '6200000001');
  select count(*) into n from app_prj02.calendar_changes where id = c;
  if n <> 0 then raise exception 'B sees A''s calendar change'; end if;
  select count(*) into n from app_prj02.calendars where family_id = current_setting('test.family_a')::uuid;
  if n <> 0 then raise exception 'B sees A''s calendar'; end if;
  r := app_prj02.decide_change(c, true);
  if r ->> 'reason' is distinct from 'unknown' then raise exception 'B decided A''s change: %', r; end if;
  if app_prj02.record_result(c, true, 'evil', null) then raise exception 'B recorded a result for A'; end if;
  blocked := false;
  begin
    insert into app_prj02.calendar_changes (family_id, run_id, action, proposal, expires_at)
      values (current_setting('test.family_a')::uuid, gen_random_uuid(), 'add', '{}', now() + interval '1 hour');
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'B wrote a change straight into the log'; end if;
  -- A's admin: no result before a yes; yes returns what to write; then the result is recorded once.
  perform app_prj02.begin_request('telegram', '7123456789');
  if app_prj02.record_result(c, true, 'evt-1', null) then raise exception 'a result was recorded before the yes'; end if;
  r := app_prj02.decide_change(c, true);
  if r ->> 'status' is distinct from 'approved' or coalesce(r -> 'proposal' ->> 'title', '') not like 'Ethan swim%' then
    raise exception 'yes did not return the change: %', r;
  end if;
  if not app_prj02.record_result(c, true, 'evt-1', null) then raise exception 'result not recorded'; end if;
  r := app_prj02.decide_change(c, true);
  if r ->> 'reason' is distinct from 'applied' then raise exception 'an applied change could be decided again: %', r; end if;
  -- No: declined, nothing to record.
  c := app_prj02.propose_change('cancel', 'evt-9', '{"title":"Piano"}', 30);
  r := app_prj02.decide_change(c, false);
  if r ->> 'status' is distinct from 'declined' then raise exception 'no was not recorded: %', r; end if;
  if app_prj02.record_result(c, true, 'evt-9', null) then raise exception 'a declined change was recorded as written'; end if;
  -- Late yes on a proposal past its time.
  c := app_prj02.propose_change('move', 'evt-3', '{"title":"Tuition"}', 1);
  perform set_config('test.change_late', c::text, true);
end $$;
reset role;
update app_prj02.calendar_changes set expires_at = now() - interval '1 second' where id = current_setting('test.change_late')::uuid;
set local role app_prj02_bot;
do $$
declare r jsonb;
begin
  perform app_prj02.begin_request('telegram', '7123456789');
  r := app_prj02.decide_change(current_setting('test.change_late')::uuid, true);
  if r ->> 'reason' is distinct from 'expired' then raise exception 'a late yes was accepted: %', r; end if;
end $$;
reset role;
do $$
declare n int;
begin
  select count(*) into n from core.agent_runs r join app_prj02.calendar_changes c on c.run_id = r.id
   where (c.status, r.status) in (('applied', 'done'), ('declined', 'cancelled'), ('expired', 'cancelled'));
  if n <> 3 then raise exception 'agent runs do not follow the changes (% of 3)', n; end if;
end $$;

-- Trips and reminders (prj02-R1 US-3): the scheduler's role works for one family per job and sees
-- nothing else; the chat bot cannot open a job; an adult's tap assigns only their family's trips.
select app_prj02.set_family_settings(current_setting('test.family_a')::uuid, '640123', 1);
select app_prj02.set_driver(current_setting('test.person_a')::uuid, true);
set local role app_prj02_job;
do $$
declare
  v_a uuid := current_setting('test.family_a')::uuid;
  v_b uuid := current_setting('test.family_b')::uuid;
  t uuid; n int; blocked boolean; r record;
begin
  select count(*) into n from app_prj02.job_families();
  if n <> 2 then raise exception 'job_families lists % families, expected the 2 with a calendar', n; end if;
  -- A job for an unknown family opens nothing and clears any earlier context of the transaction.
  if app_prj02.begin_job(gen_random_uuid()) then raise exception 'a job opened for an unknown family'; end if;
  select count(*) into n from app_prj02.people;
  if n <> 0 then raise exception 'the job role sees % people without a job', n; end if;
  if not app_prj02.begin_job(v_a) then raise exception 'job for A not opened'; end if;
  select count(*) into n from app_prj02.people;
  if n <> 2 then raise exception 'job A sees % people, expected 2', n; end if;
  select count(*) into n from app_prj02.contacts where family_id = v_b;
  if n <> 0 then raise exception 'job A sees family B''s contacts'; end if;
  -- Travel modes (Hub row 277): A's three starting rows, nothing of B.
  select count(*) into n from app_prj02.travel_modes where family_id = v_a;
  if n <> 3 then raise exception 'job A sees % travel modes, expected 3', n; end if;
  select count(*) into n from app_prj02.travel_modes where family_id is distinct from v_a;
  if n <> 0 then raise exception 'job A sees travel modes of another family'; end if;
  perform app_prj02.job_save_place('jurong west pool', 1.34, 103.69, 35, 'onemap', 'pt');
  perform app_prj02.job_save_place('jurong west pool', 1.34, 103.69, 18, 'onemap');
  select count(*) into n from app_prj02.places where label_key = 'jurong west pool';
  if n <> 2 then raise exception 'drive and public-transport times of one place not kept apart (% rows)', n; end if;
  perform app_prj02.job_mark_scan(null, null); -- A was just scanned
  t := app_prj02.job_upsert_trip('evt-swim', '2026-11-28T15:00:00+08', '2026-11-28T16:00:00+08', 'Ethan swim 🏊', ' Jurong West ',
         18, 'onemap', '2026-11-28T14:32:00+08', '2026-11-28T15:37:00+08', '2026-11-28T14:32:00+08', '2026-11-28T15:37:00+08');
  perform set_config('test.trip_a', t::text, true);
  -- The same event again updates the same trip.
  if app_prj02.job_upsert_trip('evt-swim', '2026-11-28T15:00:00+08', '2026-11-28T16:30:00+08', 'Ethan swim 🏊', null,
       18, 'onemap', '2026-11-28T14:32:00+08', '2026-11-28T16:07:00+08', '2026-11-28T14:32:00+08', '2026-11-28T16:07:00+08') <> t then
    raise exception 'the same event made a second trip';
  end if;
  if not app_prj02.job_queue(t, 'plan', current_setting('test.person_a')::uuid, now() - interval '1 minute', '{}') then
    raise exception 'plan message not queued';
  end if;
  if app_prj02.job_queue(t, 'plan', current_setting('test.person_a')::uuid, now(), '{}') then
    raise exception 'the same plan message was queued twice';
  end if;
  blocked := false;
  begin perform app_prj02.job_queue(t, 'drop', current_setting('test.person_a')::uuid, now(), '{}');
  exception when others then blocked := true; end;
  if not blocked then raise exception 'the job queued a reminder without an adult''s tap'; end if;
  select count(*) into n from app_prj02.job_claim_due(10);
  if n <> 1 then raise exception 'job A claimed % messages, expected 1', n; end if;
  select count(*) into n from app_prj02.job_claim_due(10);
  if n <> 0 then raise exception 'a message was claimed twice'; end if;
  -- Job for B: nothing of A, and cannot attach messages to A's trip.
  perform app_prj02.begin_job(v_b);
  select count(*) into n from app_prj02.trips where family_id = v_a;
  if n <> 0 then raise exception 'job B sees A''s trips'; end if;
  select count(*) into n from app_prj02.people;
  if n <> 1 then raise exception 'job B sees % people, expected 1', n; end if;
  select count(*) into n from app_prj02.travel_modes;
  if n <> 0 then raise exception 'job B sees % travel modes of A', n; end if;
  select count(*) into n from app_prj02.places;
  if n <> 0 then raise exception 'job B sees A''s saved places'; end if;
  blocked := false;
  begin update app_prj02.travel_modes set estimate_min = 1;
  exception when insufficient_privilege then blocked := true; end;
  if not blocked then raise exception 'the job role changed travel modes directly'; end if;
  blocked := false;
  begin perform app_prj02.job_queue(t, 'clash', (select id from app_prj02.people limit 1), now(), '{}');
  exception when foreign_key_violation then blocked := true; end;
  if not blocked then raise exception 'job B queued a message on A''s trip'; end if;
  select count(*) into n from app_prj02.job_claim_due(10);
  if n <> 0 then raise exception 'job B claimed A''s messages'; end if;
  -- The job role cannot act as a person or write tables directly.
  blocked := false;
  begin perform app_prj02.begin_request('telegram', '7123456789');
  exception when insufficient_privilege then blocked := true; end;
  if not blocked then raise exception 'the job role opened a person''s request'; end if;
  blocked := false;
  begin perform app_prj02.assign_trips('[]');
  exception when insufficient_privilege then blocked := true; end;
  if not blocked then raise exception 'the job role could assign trips'; end if;
  blocked := false;
  begin delete from app_prj02.trips;
  exception when insufficient_privilege then blocked := true; end;
  if not blocked then raise exception 'the job role deleted trips directly'; end if;
  -- An unknown family opens nothing.
  if app_prj02.begin_job(gen_random_uuid()) then raise exception 'a job opened for an unknown family'; end if;
  select count(*) into n from app_prj02.people;
  if n <> 0 then raise exception 'a failed job kept the previous family''s context'; end if;
end $$;
reset role;

set local role app_prj02_bot;
do $$
declare
  t uuid := current_setting('test.trip_a')::uuid;
  v_admin_a uuid := current_setting('test.person_a')::uuid;
  r jsonb; n int; blocked boolean;
begin
  -- The chat bot cannot open a job.
  blocked := false;
  begin perform app_prj02.begin_job(current_setting('test.family_a')::uuid);
  exception when insufficient_privilege then blocked := true; end;
  if not blocked then raise exception 'the chat bot opened a job'; end if;
  -- B cannot see or assign A's trip, nor assign it to A's adult.
  perform app_prj02.begin_request('telegram', '6200000001');
  select count(*) into n from app_prj02.trips where id = t;
  if n <> 0 then raise exception 'B sees A''s trip'; end if;
  r := app_prj02.assign_trips(jsonb_build_array(jsonb_build_object('trip', t, 'mode', 'taxi')));
  if r ->> 'reason' is distinct from 'unknown' then raise exception 'B assigned A''s trip: %', r; end if;
  -- A's other adult assigns the trip to A's admin: reminders queued for the admin.
  perform app_prj02.begin_request('telegram', '5550001111');
  r := app_prj02.assign_trips(jsonb_build_array(jsonb_build_object('trip', t, 'mode', 'adult', 'person', v_admin_a)));
  if (r ->> 'ok')::boolean is not true then raise exception 'A''s adult could not assign: %', r; end if;
  select count(*) into n from app_prj02.trips where id = t and status = 'assigned' and owner_person_id = v_admin_a;
  if n <> 1 then raise exception 'trip not assigned to A''s admin'; end if;
  -- Nobody of another family can be named as owner.
  r := app_prj02.assign_trips(jsonb_build_array(jsonb_build_object('trip', t, 'mode', 'adult',
         'person', (select person_id from app_prj02.consents limit 0))));
  if r ->> 'reason' is distinct from 'bad_choice' then raise exception 'an empty owner was accepted: %', r; end if;
  -- The bot reads no reminders or places (the outbox is the scheduler's).
  select count(*) into n from app_prj02.reminders;
  if n <> 0 then raise exception 'the chat bot reads the outbox'; end if;
  blocked := false;
  begin perform count(*) from app_prj02.travel_modes;
  exception when insufficient_privilege then blocked := true; end;
  if not blocked then raise exception 'the chat bot reads travel modes'; end if;
end $$;
reset role;
do $$
declare n int;
begin
  select count(*) into n from app_prj02.reminders
   where trip_id = current_setting('test.trip_a')::uuid and kind in ('drop', 'pick') and status = 'due'
     and person_id = current_setting('test.person_a')::uuid;
  if n <> 2 then raise exception 'assignment queued % reminders for the owner, expected 2', n; end if;
  -- The tap asks the next tick to re-plan family A only.
  select count(*) into n from app_prj02.family_settings
   where family_id = current_setting('test.family_a')::uuid and last_scan_at is null;
  if n <> 1 then raise exception 'a tap did not ask for a new scan of the family'; end if;
end $$;

-- Limits (prj02-R1 US-4): pause, budget and held trips stay inside the family.
set local role app_prj02_bot;
do $$
declare t uuid := current_setting('test.trip_a')::uuid; r jsonb; blocked boolean;
begin
  -- B pauses its own family and cannot release A's trip.
  perform app_prj02.begin_request('telegram', '6200000001');
  r := app_prj02.set_pause(true);
  if (r ->> 'ok')::boolean is not true then raise exception 'B could not pause its family: %', r; end if;
  -- A: budget of A only, not paused by B.
  perform app_prj02.begin_request('telegram', '5550001111');
  r := app_prj02.budget();
  if (r ->> 'paused')::boolean is not false then raise exception 'B''s pause reached family A: %', r; end if;
  if (r ->> 'week_max_usd')::numeric is distinct from 5.00 then raise exception 'weekly budget not 5.00: %', r; end if;
  if (r ->> 'week_cost_usd')::numeric is distinct from 0 then raise exception 'A''s budget counts other costs: %', r; end if;
  -- A pauses (resumed below, after the job checks).
  perform app_prj02.set_pause(true);
  -- The chat bot cannot hold trips or read the job status.
  blocked := false;
  begin perform app_prj02.job_hold_trip(t);
  exception when insufficient_privilege then blocked := true; end;
  if not blocked then raise exception 'the chat bot held a trip'; end if;
  -- An unknown account gets no budget.
  perform app_prj02.begin_request('telegram', '9999999999');
  blocked := false;
  begin perform app_prj02.budget();
  exception when insufficient_privilege then blocked := true; end;
  if not blocked then raise exception 'an unknown account read a budget'; end if;
end $$;
reset role;
-- A's costs in core count for A only (B's cost row does not).
insert into core.cost_ledger (app, tenant_id, provider, model, purpose, cost_usd)
  values ('prj02', current_setting('test.family_b')::uuid, 'anthropic', 'claude-haiku-5-5', 'ci-test', 4.99);
-- A message already due for A (test setup as owner): it must wait while A is paused.
insert into app_prj02.reminders (family_id, trip_id, person_id, kind, send_at)
  values (current_setting('test.family_a')::uuid, current_setting('test.trip_a')::uuid,
          current_setting('test.person_a')::uuid, 'warning', now() - interval '1 minute');
set local role app_prj02_job;
do $$
declare v_a uuid := current_setting('test.family_a')::uuid; t uuid := current_setting('test.trip_a')::uuid; n int; st jsonb;
begin
  perform app_prj02.begin_job(v_a);
  -- Paused: nothing queued, nothing claimed.
  if app_prj02.job_queue(t, 'warning', current_setting('test.person_a')::uuid, now() - interval '1 minute', '{}') then
    raise exception 'a warning was queued while paused';
  end if;
  select count(*) into n from app_prj02.job_claim_due(10);
  if n <> 0 then raise exception 'a paused family got % messages', n; end if;
  st := app_prj02.job_status();
  if (st ->> 'paused')::boolean is not true then raise exception 'job status does not show the pause: %', st; end if;
  -- Held once; a second hold changes nothing.
  if not app_prj02.job_hold_trip(t) then raise exception 'trip not held'; end if;
  if app_prj02.job_hold_trip(t) then raise exception 'trip held twice'; end if;
  -- Job B cannot hold A's trip.
  perform app_prj02.begin_job(current_setting('test.family_b')::uuid);
  if app_prj02.job_hold_trip(t) then raise exception 'job B held A''s trip'; end if;
end $$;
reset role;
set local role app_prj02_bot;
do $$
declare r jsonb;
begin
  -- B cannot release A's held trip.
  perform app_prj02.begin_request('telegram', '6200000001');
  r := app_prj02.release_trip(current_setting('test.trip_a')::uuid);
  if r ->> 'reason' is distinct from 'unknown' then raise exception 'B released A''s held trip: %', r; end if;
  perform app_prj02.begin_request('telegram', '5550001111');
  r := app_prj02.release_trip(current_setting('test.trip_a')::uuid);
  if (r ->> 'ok')::boolean is not true then raise exception 'A could not release its trip: %', r; end if;
  perform app_prj02.set_pause(false);
  if (app_prj02.budget() ->> 'paused')::boolean is not false then raise exception 'resume did not work'; end if;
end $$;
reset role;
-- The day's allowance: with max 1 message a day and 1 already sent today, nothing more is claimed.
update app_prj02.family_settings set max_messages_day = 1 where family_id = current_setting('test.family_a')::uuid;
insert into app_prj02.reminders (family_id, trip_id, person_id, kind, send_at)
  select current_setting('test.family_a')::uuid, current_setting('test.trip_a')::uuid, p.id, 'warning', now() - interval '1 minute'
    from app_prj02.people p
   where p.family_id = current_setting('test.family_a')::uuid and p.id <> current_setting('test.person_a')::uuid;
set local role app_prj02_job;
do $$
declare v_a uuid := current_setting('test.family_a')::uuid; t uuid := current_setting('test.trip_a')::uuid; n int; st jsonb;
begin
  perform app_prj02.begin_job(v_a);
  st := app_prj02.job_status();
  if (st ->> 'sent_today')::int < 1 then raise exception 'sent today not counted: %', st; end if;
  select count(*) into n from app_prj02.job_claim_due(10);
  if n <> 0 then raise exception 'the daily allowance was exceeded (% claimed)', n; end if;
end $$;
reset role;
do $$
declare n int;
begin
  select count(*) into n from app_prj02.trips where id = current_setting('test.trip_a')::uuid and hold_state = 'released';
  if n <> 1 then raise exception 'released trip not kept released'; end if;
  select count(*) into n from app_prj02.family_settings
   where family_id = current_setting('test.family_b')::uuid and paused_at is not null;
  if n <> 1 then raise exception 'B''s own pause was not kept'; end if;
end $$;

-- Own plans for a clash (prj02-R1 US-6): only the adult who wrote it applies it, only in its family.
update app_prj02.family_settings set max_messages_day = 30 where family_id = current_setting('test.family_a')::uuid;
insert into app_prj02.reminders (family_id, trip_id, person_id, kind, send_at, payload)
  values (current_setting('test.family_a')::uuid, current_setting('test.trip_a')::uuid, current_setting('test.person_a')::uuid,
          'clash', now(), jsonb_build_object('trips', jsonb_build_array(current_setting('test.trip_a'))));
do $$
declare v uuid;
begin
  select id into v from app_prj02.reminders where kind = 'clash' and trip_id = current_setting('test.trip_a')::uuid
     and person_id = current_setting('test.person_a')::uuid;
  perform set_config('test.clash_a', v::text, true);
  select id into v from app_prj02.people where family_id = current_setting('test.family_b')::uuid limit 1;
  perform set_config('test.person_b', v::text, true);
end $$;
set local role app_prj02_bot;
do $$
declare r jsonb; v_plan uuid; t uuid := current_setting('test.trip_a')::uuid; blocked boolean; n int;
begin
  -- B cannot start a plan on A's clash.
  perform app_prj02.begin_request('telegram', '6200000001');
  r := app_prj02.plan_await(current_setting('test.clash_a')::uuid, 30);
  if r ->> 'reason' is distinct from 'unknown' then raise exception 'B started a plan on A''s clash: %', r; end if;
  if app_prj02.plan_pending() is not null then raise exception 'B has a pending plan'; end if;
  -- A's admin writes a plan: no drop-off, pick-up by the admin.
  perform app_prj02.begin_request('telegram', '7123456789');
  r := app_prj02.plan_await(current_setting('test.clash_a')::uuid, 30);
  v_plan := (r ->> 'plan')::uuid;
  if (app_prj02.plan_pending() ->> 'status') is distinct from 'awaiting' then raise exception 'plan not awaiting'; end if;
  if (app_prj02.plan_pending() -> 'trips' ->> 0)::uuid is distinct from t then raise exception 'plan does not list the clash trips'; end if;
  if not app_prj02.plan_propose(v_plan, jsonb_build_array(jsonb_build_object('trip', t, 'mode', 'adult',
       'person', current_setting('test.person_a'), 'drop', 'none', 'pick_at', '2026-11-28T18:00:00+08'))) then
    raise exception 'plan not proposed';
  end if;
  -- A's other adult and B cannot say yes to it.
  perform app_prj02.begin_request('telegram', '5550001111');
  r := app_prj02.plan_decide(v_plan, true);
  if r ->> 'reason' is distinct from 'not_yours' then raise exception 'another adult applied the plan: %', r; end if;
  perform app_prj02.begin_request('telegram', '6200000001');
  r := app_prj02.plan_decide(v_plan, true);
  if r ->> 'reason' is distinct from 'unknown' then raise exception 'B applied A''s plan: %', r; end if;
  -- The writer's yes applies it: no drop-off reminder, a pick-up reminder, pick-up at 18:00.
  perform app_prj02.begin_request('telegram', '7123456789');
  r := app_prj02.plan_decide(v_plan, true);
  if r ->> 'status' is distinct from 'applied' then raise exception 'plan not applied: %', r; end if;
  r := app_prj02.plan_decide(v_plan, true);
  if r ->> 'reason' is distinct from 'applied' then raise exception 'a plan was applied twice: %', r; end if;
  -- A plan that names someone of another family is refused as a whole.
  r := app_prj02.plan_await(current_setting('test.clash_a')::uuid, 30);
  v_plan := (r ->> 'plan')::uuid;
  perform app_prj02.plan_propose(v_plan, jsonb_build_array(jsonb_build_object('trip', t, 'mode', 'adult', 'person', current_setting('test.person_b'))));
  blocked := false;
  begin perform app_prj02.plan_decide(v_plan, true);
  exception when invalid_parameter_value then blocked := true; end;
  if not blocked then raise exception 'a plan named an adult of another family'; end if;
  -- The bot cannot read plans directly (functions only).
  blocked := false;
  begin select count(*) into n from app_prj02.trip_plans;
  exception when insufficient_privilege then blocked := true; end;
  if not blocked then raise exception 'the chat bot reads own plans directly'; end if;
end $$;
reset role;
do $$
declare n int;
begin
  select count(*) into n from app_prj02.trips where id = current_setting('test.trip_a')::uuid
     and drop_mode = 'none' and pick_mode is null and pick_at = '2026-11-28T18:00:00+08'
     and owner_person_id = current_setting('test.person_a')::uuid;
  if n <> 1 then raise exception 'plan not applied to the trip'; end if;
  select count(*) into n from app_prj02.reminders where trip_id = current_setting('test.trip_a')::uuid and status = 'due' and kind = 'drop';
  if n <> 0 then raise exception 'a drop-off reminder for a leg the adult said is not needed'; end if;
  select count(*) into n from app_prj02.reminders where trip_id = current_setting('test.trip_a')::uuid and status = 'due' and kind = 'pick';
  if n <> 1 then raise exception 'pick-up reminder missing'; end if;
end $$;
-- Stay rule: a leg not needed gets no reminder from a tap either.
set local role app_prj02_job;
do $$
begin
  perform app_prj02.begin_job(current_setting('test.family_a')::uuid);
  perform app_prj02.job_upsert_trip('evt-stay', '2026-11-28T16:30:00+08', '2026-11-28T18:00:00+08', 'Tennis', 'UWC 139654',
         18, 'onemap', '2026-11-28T16:02:00+08', '2026-11-28T17:37:00+08', '2026-11-28T16:02:00+08', '2026-11-28T17:37:00+08', false, true);
end $$;
reset role;
set local role app_prj02_bot;
do $$
declare r jsonb; t uuid;
begin
  perform app_prj02.begin_request('telegram', '7123456789');
  select id into t from app_prj02.trips where event_id = 'evt-stay';
  r := app_prj02.assign_trips(jsonb_build_array(jsonb_build_object('trip', t, 'mode', 'taxi')));
  if (r ->> 'ok')::boolean is not true then raise exception 'stay trip not assigned: %', r; end if;
  perform set_config('test.stay', t::text, true);
end $$;
reset role;
do $$
declare n int;
begin
  select count(*) into n from app_prj02.reminders where trip_id = current_setting('test.stay')::uuid and kind = 'drop';
  if n <> 0 then raise exception 'a drop-off reminder although the child is already there (stay rule)'; end if;
  select count(*) into n from app_prj02.reminders where trip_id = current_setting('test.stay')::uuid and kind = 'pick';
  if n <> 1 then raise exception 'stay trip pick-up reminder missing'; end if;
end $$;

-- anon and authenticated reach nothing in app_prj02.
do $$
declare blocked boolean; who text;
begin
  foreach who in array array['anon', 'authenticated'] loop
    execute format('set local role %I', who);
    blocked := false;
    begin
      perform count(*) from app_prj02.families;
    exception when insufficient_privilege then blocked := true;
    end;
    reset role;
    if not blocked then raise exception '% can read app_prj02.families', who; end if;
  end loop;
end $$;

rollback;
