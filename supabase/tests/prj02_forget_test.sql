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

-- Data in core naming the family and person 1.
insert into core.cost_ledger (app, tenant_id, provider, model, purpose)
  values ('prj02', current_setting('test.family')::uuid, 'anthropic', 'test-model', 'ci-test');
insert into core.agent_runs (app, tenant_id, goal, steps)
  values ('prj02', current_setting('test.family')::uuid, 'Remind Forget Me about swimming', '[{"step":1}]');

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
     or coalesce((d ->> 'app_prj02.calendar_changes_unlinked')::int, -1) <> 2 or coalesce((d ->> 'core.agent_runs_unlinked')::int, -1) <> 1 then
    raise exception 'first forget log counts wrong: %', d;
  end if;
  -- Calendar changes stay in the family's log without the person; the waiting run lost its link.
  select count(*) into n from app_prj02.calendar_changes where family_id = v_family and person_id is null;
  if n <> 2 then raise exception 'calendar changes lost or still linked to person 1 (% unlinked)', n; end if;
  select count(*) into n from core.agent_runs where app = 'prj02' and waiting_for::text like '%' || v_p1::text || '%';
  if n <> 0 then raise exception 'an agent run still waits for person 1'; end if;
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
     or coalesce((d ->> 'app_prj02.calendars')::int, -1) <> 1 then
    raise exception 'second forget log counts wrong: %', d;
  end if;
  if d::text like '%' || v_p2::text || '%' or d::text like '%7000000%' then
    raise exception 'forget log identifies the person: %', d;
  end if;
end $$;

rollback;
