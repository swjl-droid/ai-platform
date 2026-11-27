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
  if not (r ->> 'ok')::boolean or r ->> 'family_name' <> 'Tan family' then
    raise exception 'noisy code not recognised: %', r;
  end if;
  r := app_prj02.accept_invite(upper(v_code), 'telegram', ' 7123456789 ', E'  Wei Ling \U0001F338\t ', 'v1');
  if not (r ->> 'ok')::boolean then raise exception 'family A admin could not join: %', r; end if;
  perform set_config('test.person_a', r ->> 'person_id', true);
  -- The link is now used up, for anyone.
  r := app_prj02.accept_invite(v_code, 'telegram', '5550001111', 'Someone else', 'v1');
  if r ->> 'reason' <> 'used' then raise exception 'a used link joined someone: %', r; end if;
  -- Context: A's admin sees their family only, with their consent recorded.
  r := app_prj02.begin_request('telegram', '7123456789');
  if r ->> 'notice_version' <> 'v1' or not (r ->> 'is_admin')::boolean then
    raise exception 'context wrong: %', r;
  end if;
  select count(*) into n from app_prj02.people where display_name = E'Wei Ling \U0001F338';
  if n <> 1 then raise exception 'display name not cleaned (control characters, spaces)'; end if;
  -- A invites a second adult; that adult joins.
  r := app_prj02.create_invite(48);
  perform set_config('test.code_a2', r ->> 'code', true);
  r := app_prj02.accept_invite(current_setting('test.code_a2'), 'telegram', '5550001111', 'Ah Hock', 'v1');
  if not (r ->> 'ok')::boolean then raise exception 'second adult of A could not join: %', r; end if;
  -- A second adult who is not admin cannot invite.
  r := app_prj02.create_invite(48);
  if r ->> 'reason' <> 'not_admin' then raise exception 'a non-admin adult created an invite: %', r; end if;
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
  if not (r ->> 'ok')::boolean then raise exception 'family B admin could not join: %', r; end if;
  if r ->> 'family_id' <> current_setting('test.family_b') then raise exception 'B joined the wrong family'; end if;
  -- An account already in a family cannot join another one.
  r := app_prj02.accept_invite(current_setting('test.code_a3'), 'telegram', '6200000001', 'Mdm Lim', 'v1');
  if r ->> 'reason' <> 'already_member' then raise exception 'B joined family A as well: %', r; end if;
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
  if r ->> 'reason' <> 'unknown' then raise exception 'unknown code accepted: %', r; end if;
end $$;

reset role;
update app_prj02.invites set expires_at = now() - interval '1 minute'
 where code_hash = app_prj02.code_hash(current_setting('test.code_a3'));
set local role app_prj02_bot;
do $$
declare r jsonb;
begin
  r := app_prj02.accept_invite(current_setting('test.code_a3'), 'telegram', '8800000002', 'Late uncle', 'v1');
  if r ->> 'reason' <> 'expired' then raise exception 'an expired link joined someone: %', r; end if;
end $$;
reset role;

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
