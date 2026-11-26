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
end $$;

reset role;
rollback;
