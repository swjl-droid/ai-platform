-- Forget-me test, prj01 (platform plan condition 2, CLAUDE.md "Forget me" rule 6; Hub row 213):
-- create a person, add data everywhere the platform keeps it, forget them, check nothing that
-- identifies them is left and the request is logged with counts only. A second person sharing an
-- organisation keeps it. Runs inside a transaction that is rolled back.
begin;

insert into auth.users (id, email) values
  ('00000000-0000-4000-b000-00000000000a', 'forget-me@example.test'),
  ('00000000-0000-4000-b000-00000000000c', 'stays@example.test');

-- The person starts the sample programme (org, membership, projects, audit row).
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-00000000000a","role":"authenticated"}', true);
select set_config('test.org', app_prj01.start_sample()::text, true);
reset role;

-- A second organisation shared with someone who stays.
do $$
declare v_shared uuid;
begin
  insert into app_prj01.orgs (name) values ('Shared org') returning id into v_shared;
  insert into app_prj01.members (org_id, user_id) values
    (v_shared, '00000000-0000-4000-b000-00000000000a'),
    (v_shared, '00000000-0000-4000-b000-00000000000c');
  insert into app_prj01.projects (org_id, name, methodology) values (v_shared, 'Shared project', 'Hybrid');
  perform set_config('test.shared', v_shared::text, true);
end $$;

-- A schedule in the person's own organisation, and one they imported into the shared organisation.
set local role authenticated;
select set_config('test.sched_own', app_prj01.import_schedule(
  (select id from app_prj01.projects where org_id = current_setting('test.org')::uuid order by name limit 1),
  'PMI-PMBOK', 'own.csv',
  '[{"key":"T1","name":"Design","type":"Task","start":"2026-10-01","finish":"2026-10-07"},
    {"key":"T2","name":"Build","type":"Task","start":"2026-10-08","finish":"2026-10-19"}]'::jsonb,
  '[{"from":"T1","to":"T2"}]'::jsonb)::text, true);
select set_config('test.sched_shared', app_prj01.import_schedule(
  (select id from app_prj01.projects where org_id = current_setting('test.shared')::uuid),
  'Hybrid', 'shared.csv',
  '[{"key":"G1","name":"Gate 1","type":"Macro Waterfall","start":"2026-10-07","finish":"2026-10-07"}]'::jsonb,
  '[]'::jsonb)::text, true);
reset role;

-- A transcript in the own organisation, and one dropped into the shared organisation.
set local role authenticated;
insert into app_prj01.transcripts (org_id, project_id, source_name, content, content_sha256, status)
  values (current_setting('test.org')::uuid,
          (select id from app_prj01.projects where org_id = current_setting('test.org')::uuid order by name limit 1),
          'own.txt', repeat('The person speaks in the clinic sync. ', 10), repeat('d', 64), 'matched');
insert into app_prj01.transcripts (org_id, source_name, content, content_sha256, status)
  values (current_setting('test.shared')::uuid, 'shared.txt', repeat('Shared organisation meeting notes. ', 10), repeat('e', 64), 'needs_choice');
reset role;

-- Data in core: a cost row, an agent run, an audit row naming the person.
insert into core.cost_ledger (app, tenant_id, provider, model, purpose)
  values ('prj01', current_setting('test.org')::uuid, 'anthropic', 'test-model', 'ci-test');
insert into core.agent_runs (app, tenant_id, goal, steps)
  values ('prj01', current_setting('test.org')::uuid, 'Draft minutes for Clinic relocation', '[{"step":1}]');
insert into core.audit_log (app, tenant_id, actor, action, detail)
  values ('prj01', current_setting('test.org')::uuid, '00000000-0000-4000-b000-00000000000a', 'login', '{"email":"forget-me@example.test"}');

-- The person asks to be forgotten.
set local role authenticated;
select app_prj01.forget_me();
reset role;

do $$
declare
  v_org    uuid := current_setting('test.org')::uuid;
  v_shared uuid := current_setting('test.shared')::uuid;
  v_user   uuid := '00000000-0000-4000-b000-00000000000a';
  n int;
  d jsonb;
begin
  select count(*) into n from auth.users where id = v_user;
  if n <> 0 then raise exception 'sign-in account still there'; end if;
  select count(*) into n from app_prj01.members where user_id = v_user;
  if n <> 0 then raise exception '% memberships left', n; end if;
  select count(*) into n from app_prj01.orgs where id = v_org;
  if n <> 0 then raise exception 'own organisation left'; end if;
  select count(*) into n from app_prj01.projects where org_id = v_org;
  if n <> 0 then raise exception '% projects of the own organisation left', n; end if;
  -- The shared organisation stays for the other member.
  select count(*) into n from app_prj01.projects where org_id = v_shared;
  if n <> 1 then raise exception 'shared organisation lost its project'; end if;
  select count(*) into n from app_prj01.members where org_id = v_shared;
  if n <> 1 then raise exception 'shared organisation has % members, expected 1', n; end if;
  -- Schedules: the own organisation's are gone; the shared one stays, no longer linked to the person.
  select count(*) into n from app_prj01.schedules where id = current_setting('test.sched_own')::uuid;
  if n <> 0 then raise exception 'own schedule left'; end if;
  select count(*) into n from app_prj01.schedule_items where schedule_id = current_setting('test.sched_own')::uuid;
  if n <> 0 then raise exception '% own schedule items left', n; end if;
  select count(*) into n from app_prj01.schedules
   where id = current_setting('test.sched_shared')::uuid and imported_by is null;
  if n <> 1 then raise exception 'shared schedule lost, or still linked to the person'; end if;
  -- Transcripts: the own organisation's are gone; the shared one stays, unlinked from the person.
  select count(*) into n from app_prj01.transcripts where org_id = v_org;
  if n <> 0 then raise exception '% own transcripts left', n; end if;
  select count(*) into n from app_prj01.transcripts where org_id = v_shared and uploaded_by is null;
  if n <> 1 then raise exception 'shared transcript lost, or still linked to the person'; end if;
  -- core: rows kept, link removed.
  select count(*) into n from core.cost_ledger where tenant_id = v_org;
  if n <> 0 then raise exception 'cost rows still linked'; end if;
  select count(*) into n from core.cost_ledger where purpose = 'ci-test' and tenant_id is null;
  if n <> 1 then raise exception 'cost row not kept for accounting'; end if;
  select count(*) into n from core.audit_log
   where tenant_id = v_org or actor = v_user::text or detail::text like '%forget-me@%';
  if n <> 0 then raise exception '% audit rows still identify the person', n; end if;
  select count(*) into n from core.agent_runs where tenant_id = v_org and (goal <> '' or steps <> '[]'::jsonb);
  if n <> 0 then raise exception 'agent run goal or steps not emptied'; end if;
  -- The request is logged, with counts and nothing that identifies the person.
  select detail into d from core.audit_log where app = 'prj01' and action = 'forget' order by id desc limit 1;
  if d is null then raise exception 'forget request not logged'; end if;
  if (d ->> 'app_prj01.projects')::int <> 3 or (d ->> 'auth.users')::int <> 1
     or (d ->> 'app_prj01.schedules')::int <> 1 or (d ->> 'app_prj01.schedule_items')::int <> 2
     or (d ->> 'app_prj01.schedule_links')::int <> 1 or (d ->> 'app_prj01.schedules_unlinked')::int <> 1
     or (d ->> 'app_prj01.transcripts')::int <> 1 or (d ->> 'app_prj01.transcripts_unlinked')::int <> 1 then
    raise exception 'forget log counts wrong: %', d;
  end if;
  if d::text like '%' || v_user::text || '%' or d::text like '%@%' then
    raise exception 'forget log identifies the person: %', d;
  end if;
end $$;

rollback;
