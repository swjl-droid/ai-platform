-- Separation test, prj01 (platform plan condition 3, Hub rows 211 and 213; story prj01-R1 US-1):
-- two signed-in users each start the sample programme; user B sees nothing of user A and cannot
-- change it. Runs inside a transaction that is rolled back.
begin;

insert into auth.users (id, email) values
  ('00000000-0000-4000-a000-00000000000a', 'user-a@example.test'),
  ('00000000-0000-4000-a000-00000000000b', 'user-b@example.test');

-- User A signs in and gets the sample programme.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000000a","role":"authenticated"}', true);
do $$
declare v_org uuid; v_again uuid; n int;
begin
  v_org := app_prj01.start_sample();
  v_again := app_prj01.start_sample();
  if v_org is distinct from v_again then raise exception 'start_sample made a second organisation'; end if;
  select count(*) into n from app_prj01.projects;
  if n < 2 then raise exception 'user A sees % sample projects, expected at least 2', n; end if;
  select count(*) into n from app_prj01.orgs;
  if n <> 1 then raise exception 'user A sees % organisations, expected 1', n; end if;
  perform set_config('test.org_a', v_org::text, true);
end $$;

-- User B signs in and gets their own copy.
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000000b","role":"authenticated"}', true);
do $$
declare
  v_org_a uuid := current_setting('test.org_a')::uuid;
  v_org_b uuid;
  n int;
  blocked boolean;
begin
  v_org_b := app_prj01.start_sample();
  if v_org_b = v_org_a then raise exception 'user B was put in user A''s organisation'; end if;

  -- B sees only B's rows.
  select count(*) into n from app_prj01.orgs where id = v_org_a;
  if n <> 0 then raise exception 'user B sees user A''s organisation'; end if;
  select count(*) into n from app_prj01.projects where org_id = v_org_a;
  if n <> 0 then raise exception 'user B sees % of user A''s projects', n; end if;
  select count(*) into n from app_prj01.members where org_id = v_org_a;
  if n <> 0 then raise exception 'user B sees user A''s membership'; end if;
  select count(*) into n from app_prj01.projects;
  if n <> 3 then raise exception 'user B sees % projects, expected their own 3', n; end if;

  -- B cannot change A's data: updates and deletes find nothing, inserts are refused.
  update app_prj01.projects set name = 'taken over' where org_id = v_org_a;
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'user B changed % of user A''s projects', n; end if;
  delete from app_prj01.projects where org_id = v_org_a;
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'user B deleted % of user A''s projects', n; end if;
  blocked := false;
  begin
    insert into app_prj01.projects (org_id, name, methodology) values (v_org_a, 'planted', 'Agile');
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'user B added a project to user A''s organisation'; end if;
  -- B cannot move their own project into A's organisation.
  blocked := false;
  begin
    update app_prj01.projects set org_id = v_org_a where org_id = v_org_b;
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'user B moved a project into user A''s organisation'; end if;
  -- B cannot join A's organisation or create one by hand.
  blocked := false;
  begin
    insert into app_prj01.members (org_id, user_id) values (v_org_a, '00000000-0000-4000-a000-00000000000b');
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'user B joined user A''s organisation'; end if;
  -- B cannot forget A or read core.
  blocked := false;
  begin
    perform app_prj01.forget('00000000-0000-4000-a000-00000000000a');
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'user B could call forget() for user A'; end if;
  blocked := false;
  begin
    perform count(*) from core.audit_log;
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'user B could read core.audit_log'; end if;
end $$;

-- Schedules (prj01-R1 US-2): user A imports one; user B sees, adds and deletes nothing of it.
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000000a","role":"authenticated"}', true);
do $$
declare v_project uuid; v_sched uuid; n int;
begin
  select id into v_project from app_prj01.projects order by name limit 1;
  v_sched := app_prj01.import_schedule(v_project, 'PMI-PMBOK', 'a.csv',
    '[{"key":"T1","name":"Design","type":"Task","start":"2026-10-01","finish":"2026-10-07"},
      {"key":"T2","name":"Build","type":"Task","parent":"T1","start":"2026-10-08","finish":"2026-10-19"}]'::jsonb,
    '[{"from":"T1","to":"T2","type":"FS","lag":2}]'::jsonb);
  select count(*) into n from app_prj01.schedule_items where schedule_id = v_sched;
  if n <> 2 then raise exception 'user A reads back % items, expected 2', n; end if;
  select count(*) into n from app_prj01.schedule_links where schedule_id = v_sched and lag_days = 2;
  if n <> 1 then raise exception 'user A reads back % links, expected 1', n; end if;
  perform set_config('test.sched_a', v_sched::text, true);
  perform set_config('test.project_a', v_project::text, true);
end $$;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000000b","role":"authenticated"}', true);
do $$
declare
  v_sched_a   uuid := current_setting('test.sched_a')::uuid;
  v_project_a uuid := current_setting('test.project_a')::uuid;
  v_org_a     uuid := current_setting('test.org_a')::uuid;
  v_project_b uuid;
  v_sched_b   uuid;
  n int;
  blocked boolean;
begin
  select count(*) into n from app_prj01.schedules where id = v_sched_a;
  if n <> 0 then raise exception 'user B sees user A''s schedule'; end if;
  select count(*) into n from app_prj01.schedule_items where schedule_id = v_sched_a;
  if n <> 0 then raise exception 'user B sees % of user A''s schedule items', n; end if;
  select count(*) into n from app_prj01.schedule_links where schedule_id = v_sched_a;
  if n <> 0 then raise exception 'user B sees user A''s schedule links'; end if;
  delete from app_prj01.schedules where id = v_sched_a;
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'user B deleted user A''s schedule'; end if;
  -- B cannot import into A's project.
  blocked := false;
  begin
    perform app_prj01.import_schedule(v_project_a, 'Agile', 'b.csv',
      '[{"key":"X","name":"planted","type":"Spike","start":"2026-10-01","finish":"2026-10-02"}]'::jsonb, '[]'::jsonb);
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'user B imported a schedule into user A''s project'; end if;
  -- B cannot add an item to A's schedule, even claiming A's organisation.
  blocked := false;
  begin
    insert into app_prj01.schedule_items (schedule_id, org_id, position, key, name, type)
      values (v_sched_a, v_org_a, 9, 'X9', 'planted', 'Task');
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'user B added an item to user A''s schedule'; end if;
  -- B cannot attach a schedule of B's own organisation to A's project (composite key).
  select id into v_project_b from app_prj01.projects order by name limit 1;
  v_sched_b := app_prj01.import_schedule(v_project_b, 'Agile', 'b.csv',
    '[{"key":"S1","name":"Spike","type":"Spike","start":"2026-10-01","finish":"2026-10-02"}]'::jsonb, '[]'::jsonb);
  blocked := false;
  begin
    insert into app_prj01.schedules (org_id, project_id, method, source_name, item_count, link_count)
      values ((select org_id from app_prj01.schedules where id = v_sched_b), v_project_a, 'Agile', 'x', 0, 0);
  exception when foreign_key_violation or insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'user B tied a schedule to user A''s project'; end if;
end $$;

-- Transcripts (prj01-R1 US-3): user A drops one; user B sees, changes, confirms and adds nothing of it.
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000000a","role":"authenticated"}', true);
do $$
declare v_id uuid; n int; blocked boolean;
begin
  insert into app_prj01.transcripts (org_id, project_id, source_name, content, content_sha256, status)
    values (current_setting('test.org_a')::uuid, current_setting('test.project_a')::uuid, 'a.txt',
            repeat('Weekly sync of the clinic relocation. ', 10), repeat('a', 64), 'matched')
    returning id into v_id;
  perform set_config('test.transcript_a', v_id::text, true);
  -- The same text again in the same organisation is refused.
  blocked := false;
  begin
    insert into app_prj01.transcripts (org_id, project_id, source_name, content, content_sha256, status)
      values (current_setting('test.org_a')::uuid, current_setting('test.project_a')::uuid, 'again.txt',
              repeat('Weekly sync of the clinic relocation. ', 10), repeat('a', 64), 'matched');
  exception when unique_violation then blocked := true;
  end;
  if not blocked then raise exception 'the same transcript was stored twice'; end if;
  -- The text itself cannot be changed.
  blocked := false;
  begin
    update app_prj01.transcripts set content = repeat('x', 300) where id = v_id;
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'a transcript text could be changed'; end if;
end $$;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000000b","role":"authenticated"}', true);
do $$
declare
  v_tr_a  uuid := current_setting('test.transcript_a')::uuid;
  v_org_a uuid := current_setting('test.org_a')::uuid;
  v_project_a uuid := current_setting('test.project_a')::uuid;
  v_org_b uuid;
  n int;
  blocked boolean;
begin
  select count(*) into n from app_prj01.transcripts where id = v_tr_a;
  if n <> 0 then raise exception 'user B sees user A''s transcript'; end if;
  update app_prj01.transcripts set status = 'confirmed' where id = v_tr_a;
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'user B confirmed user A''s transcript'; end if;
  delete from app_prj01.transcripts where id = v_tr_a;
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'user B deleted user A''s transcript'; end if;
  blocked := false;
  begin
    insert into app_prj01.transcripts (org_id, source_name, content, content_sha256, status)
      values (v_org_a, 'planted.txt', repeat('planted text ', 30), repeat('b', 64), 'needs_choice');
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'user B dropped a transcript into user A''s organisation'; end if;
  -- B cannot tie a transcript of B's organisation to A's project.
  select org_id into v_org_b from app_prj01.members limit 1;
  blocked := false;
  begin
    insert into app_prj01.transcripts (org_id, project_id, source_name, content, content_sha256, status)
      values (v_org_b, v_project_a, 'b.txt', repeat('text of b ', 30), repeat('c', 64), 'confirmed');
  exception when foreign_key_violation or insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'user B tied a transcript to user A''s project'; end if;
end $$;

-- Nobody signed in (anon) gets nothing at all.
reset role;
set local role anon;
do $$
declare blocked boolean := false;
begin
  begin
    perform count(*) from app_prj01.projects;
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'anon could read app_prj01.projects'; end if;
  blocked := false;
  begin
    perform count(*) from app_prj01.schedule_items;
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'anon could read app_prj01.schedule_items'; end if;
  blocked := false;
  begin
    perform count(*) from app_prj01.transcripts;
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'anon could read app_prj01.transcripts'; end if;
end $$;

reset role;
rollback;
