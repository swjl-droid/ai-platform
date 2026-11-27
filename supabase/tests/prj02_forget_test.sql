-- Forget-me test, prj02 (platform plan condition 2, CLAUDE.md "Forget me" rule 6; Hub row 213):
-- a family of two adults; the first forgets themselves from the bot (the family stays for the
-- other adult), then the owner forgets the second (the family is deleted with everything in it).
-- After each step nothing that identifies the person is left, and each request is logged with
-- counts only. Runs inside a transaction that is rolled back.
begin;

do $$
declare f jsonb;
begin
  f := app_prj02.create_family('Ong family', 'SG', 48);
  perform set_config('test.family', f ->> 'family_id', true);
  perform set_config('test.code', f ->> 'code', true);
end $$;

set local role app_prj02_bot;
do $$
declare r jsonb;
begin
  r := app_prj02.accept_invite(current_setting('test.code'), 'telegram', '7000000001', 'Forget Me 😀', 'v1');
  perform set_config('test.p1', r ->> 'person_id', true);
  perform app_prj02.record_consent('v2');
  r := app_prj02.create_invite(48);
  r := app_prj02.accept_invite(r ->> 'code', 'telegram', '7000000002', 'Stays', 'v1');
  perform set_config('test.p2', r ->> 'person_id', true);
  -- An open invite created by person 1, for the family.
  perform app_prj02.begin_request('telegram', '7000000001');
  perform app_prj02.create_invite(24);
end $$;
reset role;

-- Person 1 asked for two calendar changes: one written, one still waiting for their yes.
select app_prj02.set_calendar(current_setting('test.family')::uuid, 'ongfamily@group.calendar.google.com');
set local role app_prj02_bot;
do $$
declare c uuid;
begin
  perform app_prj02.begin_request('telegram', '7000000001');
  c := app_prj02.propose_change('add', null, '{"title":"Swim for Forget Me","start":"2026-11-28T15:00:00+08:00"}', 30);
  perform app_prj02.decide_change(c, true);
  perform app_prj02.record_result(c, true, 'evt-1', null);
  perform app_prj02.propose_change('cancel', 'evt-2', '{"title":"Piano with Forget Me"}', 30);
end $$;
reset role;

-- Person 1 takes a trip (assigned by person 2) and has reminders queued; the family has settings
-- and a saved place.
select app_prj02.set_family_settings(current_setting('test.family')::uuid, '520123', 1);
set local role app_prj02_job;
do $$
declare t uuid;
begin
  perform app_prj02.begin_job(current_setting('test.family')::uuid);
  perform app_prj02.job_save_place('jurong west pool', 1.34, 103.69, 18, 'onemap');
  t := app_prj02.job_upsert_trip('evt-9', now() + interval '1 day', now() + interval '25 hours', 'Swim for Forget Me', 'Jurong West pool',
         18, 'onemap', now() + interval '23 hours', now() + interval '24 hours', now() + interval '23 hours', now() + interval '24 hours');
  perform set_config('test.trip', t::text, true);
  perform app_prj02.job_queue(t, 'plan', current_setting('test.p1')::uuid, now(), '{}');
end $$;
reset role;
set local role app_prj02_bot;
do $$
begin
  perform app_prj02.begin_request('telegram', '7000000002');
  perform app_prj02.assign_trips(jsonb_build_array(jsonb_build_object('trip', current_setting('test.trip')::uuid,
    'mode', 'adult', 'person', current_setting('test.p1')::uuid)));
end $$;
reset role;

-- Data in core naming the family and person 1.
insert into core.cost_ledger (app, tenant_id, provider, model, purpose)
  values ('prj02', current_setting('test.family')::uuid, 'anthropic', 'test-model', 'ci-test');
insert into core.agent_runs (app, tenant_id, goal, steps)
  values ('prj02', current_setting('test.family')::uuid, 'Remind Forget Me about swimming', '[{"step":1}]');

-- Person 1 starts an own plan for a clash (prj02-R1 US-6).
insert into app_prj02.reminders (family_id, trip_id, person_id, kind, send_at, payload)
  values (current_setting('test.family')::uuid, current_setting('test.trip')::uuid, current_setting('test.p1')::uuid,
          'clash', now(), jsonb_build_object('trips', jsonb_build_array(current_setting('test.trip'))));
set local role app_prj02_bot;
do $$
declare r jsonb;
begin
  perform app_prj02.begin_request('telegram', '7000000001');
  r := app_prj02.plan_await((select id from app_prj02.reminders where kind = 'clash' limit 0), 30);
  if r ->> 'reason' is distinct from 'unknown' then raise exception 'an empty clash was accepted: %', r; end if;
end $$;
reset role;
do $$
declare v uuid;
begin
  select id into v from app_prj02.reminders where kind = 'clash' and person_id = current_setting('test.p1')::uuid;
  perform set_config('test.clash', v::text, true);
end $$;
set local role app_prj02_bot;
do $$
declare r jsonb;
begin
  perform app_prj02.begin_request('telegram', '7000000001');
  r := app_prj02.plan_await(current_setting('test.clash')::uuid, 30);
  if (r ->> 'ok')::boolean is not true then raise exception 'own plan not started: %', r; end if;
end $$;
reset role;

-- Person 1 forgets themselves from the bot.
set local role app_prj02_bot;
do $$
begin
  perform app_prj02.begin_request('telegram', '7000000001');
  perform app_prj02.forget_me();
  -- The account is now unknown.
  if app_prj02.begin_request('telegram', '7000000001') is not null then
    raise exception 'forgotten account still has a context';
  end if;
end $$;
reset role;

do $$
declare
  v_family uuid := current_setting('test.family')::uuid;
  v_p1     uuid := current_setting('test.p1')::uuid;
  n int;
  d jsonb;
begin
  select count(*) into n from app_prj02.trip_plans where person_id = v_p1;
  if n <> 0 then raise exception 'own plans of the forgotten person left'; end if;
  select detail into d from core.audit_log where app = 'prj02' and action = 'forget' order by id desc limit 1;
  if coalesce((d ->> 'app_prj02.trip_plans')::int, -1) <> 1 then raise exception 'forget log does not count the own plan: %', d; end if;
  select count(*) into n from app_prj02.people where id = v_p1;
  if n <> 0 then raise exception 'person 1 still there'; end if;
  select count(*) into n from app_prj02.contacts where external_id = '7000000001';
  if n <> 0 then raise exception 'person 1''s Telegram account still there'; end if;
  select count(*) into n from app_prj02.consents where person_id = v_p1;
  if n <> 0 then raise exception 'person 1''s consents still there'; end if;
  select count(*) into n from app_prj02.request_ctx where person_id = v_p1;
  if n <> 0 then raise exception 'person 1''s request contexts still there'; end if;
  select count(*) into n from app_prj02.invites where created_by = v_p1 or used_by = v_p1;
  if n <> 0 then raise exception 'invites still linked to person 1'; end if;
  -- The family stays for person 2, with its invites and core rows.
  select count(*) into n from app_prj02.families where id = v_family;
  if n <> 1 then raise exception 'family deleted while person 2 is still in it'; end if;
  select count(*) into n from app_prj02.invites where family_id = v_family;
  if n <> 3 then raise exception 'family has % invites, expected 3', n; end if;
  select count(*) into n from core.cost_ledger where tenant_id = v_family;
  if n <> 1 then raise exception 'cost row unlinked while the family stays'; end if;
  select count(*) into n from core.audit_log where actor = v_p1::text;
  if n <> 0 then raise exception '% audit rows still name person 1', n; end if;
  select detail into d from core.audit_log where app = 'prj02' and action = 'forget' order by id desc limit 1;
  if coalesce((d ->> 'app_prj02.people')::int, -1) <> 1 or coalesce((d ->> 'app_prj02.contacts')::int, -1) <> 1
     or coalesce((d ->> 'app_prj02.consents')::int, -1) <> 2 or coalesce((d ->> 'app_prj02.families')::int, -1) <> 0
     or coalesce((d ->> 'app_prj02.invites_unlinked')::int, -1) <> 3
     or coalesce((d ->> 'app_prj02.calendar_changes_unlinked')::int, -1) <> 2 or coalesce((d ->> 'core.agent_runs_unlinked')::int, -1) <> 1
     or coalesce((d ->> 'app_prj02.trips_unlinked')::int, -1) <> 1 or coalesce((d ->> 'app_prj02.reminders')::int, -1) <> 4 then -- plan, drop, pick and the clash of the own plan (US-6)
    raise exception 'first forget log counts wrong: %', d;
  end if;
  -- Calendar changes stay in the family's log without the person; the waiting run lost its link.
  select count(*) into n from app_prj02.calendar_changes where family_id = v_family and person_id is null;
  if n <> 2 then raise exception 'calendar changes lost or still linked to person 1 (% unlinked)', n; end if;
  select count(*) into n from core.agent_runs where app = 'prj02' and waiting_for::text like '%' || v_p1::text || '%';
  if n <> 0 then raise exception 'an agent run still waits for person 1'; end if;
  select count(*) into n from app_prj02.trips where owner_person_id = v_p1 or assigned_by = v_p1;
  if n <> 0 then raise exception 'a trip still names person 1'; end if;
  select count(*) into n from app_prj02.trips where family_id = v_family and status = 'assigned' and owner_person_id is null;
  if n <> 1 then raise exception 'the family lost its trip, or it still has an owner'; end if;
  select count(*) into n from app_prj02.reminders where person_id = v_p1;
  if n <> 0 then raise exception 'reminders for person 1 left'; end if;
end $$;

-- The owner forgets person 2 (a request received another way): the family goes too.
select app_prj02.forget(current_setting('test.p2')::uuid);

do $$
declare
  v_family uuid := current_setting('test.family')::uuid;
  v_p2     uuid := current_setting('test.p2')::uuid;
  n int;
  d jsonb;
begin
  select count(*) into n from app_prj02.families where id = v_family;
  if n <> 0 then raise exception 'empty family still there'; end if;
  select count(*) into n from app_prj02.invites where family_id = v_family;
  if n <> 0 then raise exception '% invites of the family left', n; end if;
  select count(*) into n from app_prj02.contacts where external_id in ('7000000001', '7000000002');
  if n <> 0 then raise exception 'Telegram accounts left'; end if;
  select count(*) into n from app_prj02.calendar_changes where family_id = v_family;
  if n <> 0 then raise exception 'calendar changes of the family left'; end if;
  select count(*) into n from app_prj02.calendars where family_id = v_family;
  if n <> 0 then raise exception 'calendar link of the family left'; end if;
  select count(*) into n from app_prj02.trips where family_id = v_family;
  if n <> 0 then raise exception 'trips of the family left'; end if;
  select count(*) into n from app_prj02.places where family_id = v_family;
  if n <> 0 then raise exception 'saved places of the family left'; end if;
  select count(*) into n from app_prj02.family_settings where family_id = v_family;
  if n <> 0 then raise exception 'family settings left'; end if;
  select count(*) into n from app_prj02.travel_modes where family_id = v_family;
  if n <> 0 then raise exception 'travel modes of the family left'; end if;
  -- core: rows kept, link removed.
  select count(*) into n from core.cost_ledger where tenant_id = v_family;
  if n <> 0 then raise exception 'cost rows still linked'; end if;
  select count(*) into n from core.cost_ledger where purpose = 'ci-test' and app = 'prj02' and tenant_id is null;
  if n <> 1 then raise exception 'cost row not kept for accounting'; end if;
  select count(*) into n from core.audit_log
   where app = 'prj02' and (tenant_id = v_family or actor in (v_p2::text, current_setting('test.p1'))
                            or detail::text like '%7000000%' or detail::text like '%Forget Me%');
  if n <> 0 then raise exception '% audit rows still identify the family or a person', n; end if;
  select count(*) into n from core.agent_runs where tenant_id = v_family and (goal <> '' or steps <> '[]'::jsonb);
  if n <> 0 then raise exception 'agent run goal or steps not emptied'; end if;
  select detail into d from core.audit_log where app = 'prj02' and action = 'forget' order by id desc limit 1;
  if coalesce((d ->> 'app_prj02.people')::int, -1) <> 1 or coalesce((d ->> 'app_prj02.families')::int, -1) <> 1
     or coalesce((d ->> 'app_prj02.invites')::int, -1) <> 3 or coalesce((d ->> 'core.cost_ledger')::int, -1) <> 1
     or coalesce((d ->> 'core.agent_runs')::int, -1) <> 3 or coalesce((d ->> 'app_prj02.calendar_changes')::int, -1) <> 2
     or coalesce((d ->> 'app_prj02.calendars')::int, -1) <> 1 or coalesce((d ->> 'app_prj02.trips')::int, -1) <> 1
     or coalesce((d ->> 'app_prj02.places')::int, -1) <> 1 or coalesce((d ->> 'app_prj02.family_settings')::int, -1) <> 1
     or coalesce((d ->> 'app_prj02.travel_modes')::int, -1) <> 3 then
    raise exception 'second forget log counts wrong: %', d;
  end if;
  if d::text like '%' || v_p2::text || '%' or d::text like '%7000000%' then
    raise exception 'forget log identifies the person: %', d;
  end if;
end $$;

rollback;
