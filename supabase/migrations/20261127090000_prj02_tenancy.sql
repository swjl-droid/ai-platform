-- ai-platform: first tenant tables of prj02 (Family orchestrator), story prj02-R1 US-1 (bot and
-- join flow) and Hub row 213 (platform plan conditions 2 and 3, Hub row 211).
-- PROVISIONAL VERSION: renamed to the version Supabase records once applied (CLAUDE.md rule 3).
--
-- Who is asking (decision 27/11/2026, Hub row 249, option A). prj02 users talk to Telegram, not to
-- Supabase Auth, so nobody signs in to the database. The bot's server code connects as the
-- dedicated role app_prj02_bot and, for each message, calls begin_request(channel, account) with
-- the account Telegram reported. That function looks the account up in contacts and records the
-- person for the current transaction in request_ctx, a table the bot role cannot write. Every
-- policy goes through is_member(), which reads request_ctx for the current transaction only. The
-- bot role can never name a person or family directly; an unknown account gets no context and
-- sees nothing.
--
-- Separation rule (CLAUDE.md "Tenant separation"): every table carries family_id and has RLS
-- through app_prj02.is_member(); families is the 'tenant root'. Composite foreign keys tie each
-- row to its family, so a row can never point at another family's person.
--
-- Channel layer (Hub row 116): a person is one row in people; a Telegram account is one row in
-- contacts, so a WhatsApp number can be added later as another contact without changing the rest.
--
-- Who may do what:
--   anon, authenticated  nothing in app_prj02 (the schema is not exposed in the Data API)
--   app_prj02_bot        read rows of the family of the person in the current request; every
--                        change goes through the functions below (join, consent, invite,
--                        forget_me); no direct insert, update or delete
--   owner (postgres)     create_family() for a new family's first invite, forget(person) for a
--                        request received another way
-- core stays server-only: the functions reach it as their owner (security definer).

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'app_prj02_bot') then
    -- No password here: John sets it in the Supabase SQL editor, so no secret is in git.
    create role app_prj02_bot login noinherit nobypassrls connection limit 10;
  end if;
end $$;
alter role app_prj02_bot set statement_timeout = '5s';

create table app_prj02.families (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(name) between 1 and 80),
  country     text not null default 'SG' check (country ~ '^[A-Z]{2}$'),
  created_at  timestamptz not null default now()
);
comment on table app_prj02.families is 'tenant root: one row per family; its id is the family_id of every other prj02 table';

create table app_prj02.people (
  id            uuid primary key default gen_random_uuid(),
  family_id     uuid not null references app_prj02.families (id) on delete cascade,
  display_name  text not null check (length(display_name) between 1 and 80),
  role          text not null default 'adult' check (role in ('adult', 'child')),
  is_admin      boolean not null default false,
  created_at    timestamptz not null default now(),
  unique (id, family_id)
);
create index people_family on app_prj02.people (family_id);

-- One row per way of reaching a person (release 1: Telegram). An account belongs to one person.
create table app_prj02.contacts (
  id           uuid primary key default gen_random_uuid(),
  family_id    uuid not null,
  person_id    uuid not null,
  channel      text not null check (channel in ('telegram')),
  external_id  text not null check (external_id ~ '^[0-9]{1,20}$'),
  created_at   timestamptz not null default now(),
  unique (channel, external_id),
  foreign key (person_id, family_id) references app_prj02.people (id, family_id) on delete cascade
);
create index contacts_person on app_prj02.contacts (person_id);

-- Each 'I agree' to a version of the data notice (Hub row 146).
create table app_prj02.consents (
  id              uuid primary key default gen_random_uuid(),
  family_id       uuid not null,
  person_id       uuid not null,
  notice_version  text not null check (notice_version ~ '^[a-z0-9.-]{1,20}$'),
  agreed_at       timestamptz not null default now(),
  unique (person_id, notice_version),
  foreign key (person_id, family_id) references app_prj02.people (id, family_id) on delete cascade
);

-- One-time join links. Only the SHA-256 of the code is kept; the code itself is shown once.
create table app_prj02.invites (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references app_prj02.families (id) on delete cascade,
  code_hash   bytea not null unique,
  is_admin    boolean not null default false,
  created_by  uuid,
  expires_at  timestamptz not null,
  used_by     uuid,
  used_at     timestamptz,
  created_at  timestamptz not null default now(),
  foreign key (created_by, family_id) references app_prj02.people (id, family_id) on delete set null (created_by),
  foreign key (used_by, family_id) references app_prj02.people (id, family_id) on delete set null (used_by)
);
create index invites_family on app_prj02.invites (family_id);

-- Who the current request is for: one row per transaction, written only by begin_request().
create table app_prj02.request_ctx (
  xact       xid8 primary key,
  family_id  uuid not null,
  person_id  uuid not null,
  at         timestamptz not null default now(),
  foreign key (person_id, family_id) references app_prj02.people (id, family_id) on delete cascade
);
create index request_ctx_at on app_prj02.request_ctx (at);

-- Membership check used by every policy: is the family that of the person this transaction was
-- opened for? pg_current_xact_id_if_assigned() is null before begin_request() has written, so a
-- request without a context matches nothing.
create function app_prj02.is_member(p_family uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from app_prj02.request_ctx r
     where r.xact = pg_catalog.pg_current_xact_id_if_assigned() and r.family_id = p_family
  );
$$;

create function app_prj02.current_person() returns uuid
language sql stable security definer set search_path = '' as $$
  select r.person_id from app_prj02.request_ctx r
   where r.xact = pg_catalog.pg_current_xact_id_if_assigned();
$$;

alter table app_prj02.families    enable row level security;
alter table app_prj02.people      enable row level security;
alter table app_prj02.contacts    enable row level security;
alter table app_prj02.consents    enable row level security;
alter table app_prj02.invites     enable row level security;
alter table app_prj02.request_ctx enable row level security;

-- One policy per line (scripts/ci/separation_selftest.sh plants a leak by rewriting one of them).
create policy families_read on app_prj02.families for select to app_prj02_bot using (app_prj02.is_member(id));
create policy people_read on app_prj02.people for select to app_prj02_bot using (app_prj02.is_member(family_id));
create policy contacts_read on app_prj02.contacts for select to app_prj02_bot using (app_prj02.is_member(family_id));
create policy consents_read on app_prj02.consents for select to app_prj02_bot using (app_prj02.is_member(family_id));
create policy invites_read on app_prj02.invites for select to app_prj02_bot using (app_prj02.is_member(family_id));
-- request_ctx is read only by the functions above; the bot role has no grant on it.
create policy request_ctx_none on app_prj02.request_ctx for select to app_prj02_bot using (false);

-- Opens the request for the account Telegram reported. Returns the person, family and latest
-- consent, or null for an account that has not joined (the context is cleared, so it sees nothing).
create function app_prj02.begin_request(p_channel text, p_account text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_xact xid8 := pg_catalog.pg_current_xact_id();
  r record;
begin
  delete from app_prj02.request_ctx where at < now() - interval '15 minutes';
  select c.person_id, c.family_id, p.display_name, p.role, p.is_admin
    into r
    from app_prj02.contacts c join app_prj02.people p on p.id = c.person_id
   where c.channel = p_channel and c.external_id = btrim(p_account);
  if not found then
    -- An earlier context of this transaction must not carry over to an unknown account.
    delete from app_prj02.request_ctx where xact = v_xact;
    return null;
  end if;
  insert into app_prj02.request_ctx (xact, family_id, person_id) values (v_xact, r.family_id, r.person_id)
    on conflict (xact) do update set family_id = excluded.family_id, person_id = excluded.person_id, at = now();
  return jsonb_build_object(
    'person_id', r.person_id, 'family_id', r.family_id, 'display_name', r.display_name,
    'role', r.role, 'is_admin', r.is_admin,
    'notice_version', (select c.notice_version from app_prj02.consents c
                        where c.person_id = r.person_id order by c.agreed_at desc limit 1));
end;
$$;

-- Normalises a code as typed or forwarded: case and spaces do not matter.
create function app_prj02.code_hash(p_code text) returns bytea
language sql immutable set search_path = '' as $$
  select pg_catalog.sha256(convert_to(lower(regexp_replace(coalesce(p_code, ''), '\s', '', 'g')), 'UTF8'));
$$;

-- What a join link would do, before the person agrees. Says nothing about the family but its name.
create function app_prj02.preview_invite(p_code text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r record;
begin
  select i.expires_at, i.used_at, f.name into r
    from app_prj02.invites i join app_prj02.families f on f.id = i.family_id
   where i.code_hash = app_prj02.code_hash(p_code);
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown'); end if;
  if r.used_at is not null then return jsonb_build_object('ok', false, 'reason', 'used'); end if;
  if r.expires_at <= now() then return jsonb_build_object('ok', false, 'reason', 'expired'); end if;
  return jsonb_build_object('ok', true, 'family_name', r.name);
end;
$$;

-- 'I agree' on a join link: creates the person, their contact and consent in one step, uses up
-- the link, and opens the request for the new person.
create function app_prj02.accept_invite(p_code text, p_channel text, p_account text,
                                        p_display_name text, p_notice_version text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_inv     app_prj02.invites;
  v_person  uuid;
  v_name    text := left(btrim(regexp_replace(coalesce(p_display_name, ''), '[[:cntrl:]]', '', 'g')), 80);
begin
  select * into v_inv from app_prj02.invites where code_hash = app_prj02.code_hash(p_code) for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown'); end if;
  if v_inv.used_at is not null then return jsonb_build_object('ok', false, 'reason', 'used'); end if;
  if v_inv.expires_at <= now() then return jsonb_build_object('ok', false, 'reason', 'expired'); end if;
  if exists (select 1 from app_prj02.contacts where channel = p_channel and external_id = btrim(p_account)) then
    return jsonb_build_object('ok', false, 'reason', 'already_member');
  end if;
  if v_name = '' then v_name := 'Adult'; end if;
  insert into app_prj02.people (family_id, display_name, role, is_admin)
    values (v_inv.family_id, v_name, 'adult', v_inv.is_admin) returning id into v_person;
  insert into app_prj02.contacts (family_id, person_id, channel, external_id)
    values (v_inv.family_id, v_person, p_channel, btrim(p_account));
  insert into app_prj02.consents (family_id, person_id, notice_version)
    values (v_inv.family_id, v_person, p_notice_version);
  update app_prj02.invites set used_by = v_person, used_at = now() where id = v_inv.id;
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', v_inv.family_id, v_person::text, 'join', 'app_prj02.people',
            jsonb_build_object('notice_version', p_notice_version, 'channel', p_channel));
  perform app_prj02.begin_request(p_channel, p_account);
  return jsonb_build_object('ok', true, 'person_id', v_person, 'family_id', v_inv.family_id);
end;
$$;

-- 'I agree' again when the data notice changes.
create function app_prj02.record_consent(p_notice_version text) returns boolean
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  select person_id, family_id into r from app_prj02.request_ctx
   where xact = pg_catalog.pg_current_xact_id_if_assigned();
  if not found then raise exception 'no request context' using errcode = '42501'; end if;
  insert into app_prj02.consents (family_id, person_id, notice_version)
    values (r.family_id, r.person_id, p_notice_version) on conflict (person_id, notice_version) do nothing;
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', r.family_id, r.person_id::text, 'consent', 'app_prj02.consents',
            jsonb_build_object('notice_version', p_notice_version));
  return true;
end;
$$;

-- A family admin creates a one-time join link for another adult of their own family. The code is
-- returned once; only its hash is stored. p_hours comes from the app's settings.
create function app_prj02.create_invite(p_hours int, p_is_admin boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  r      record;
  v_code text := replace(gen_random_uuid()::text, '-', '');
begin
  select c.person_id, c.family_id, p.is_admin, p.role into r
    from app_prj02.request_ctx c join app_prj02.people p on p.id = c.person_id
   where c.xact = pg_catalog.pg_current_xact_id_if_assigned();
  if not found then raise exception 'no request context' using errcode = '42501'; end if;
  if not r.is_admin or r.role <> 'adult' then
    return jsonb_build_object('ok', false, 'reason', 'not_admin');
  end if;
  if p_hours is null or p_hours not between 1 and 168 then
    raise exception 'invite hours must be between 1 and 168';
  end if;
  insert into app_prj02.invites (family_id, code_hash, is_admin, created_by, expires_at)
    values (r.family_id, app_prj02.code_hash(v_code), p_is_admin, r.person_id, now() + make_interval(hours => p_hours));
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', r.family_id, r.person_id::text, 'invite', 'app_prj02.invites',
            jsonb_build_object('hours', p_hours, 'is_admin', p_is_admin));
  return jsonb_build_object('ok', true, 'code', v_code, 'expires_at', now() + make_interval(hours => p_hours));
end;
$$;

-- A message from an account that has not joined: counted, without the account or its content.
create function app_prj02.note_refusal(p_channel text) returns void
language sql security definer set search_path = '' as $$
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', null, 'unknown', 'refused', null, jsonb_build_object('channel', p_channel));
$$;

-- A new family and the first admin's join link (run by the owner, e.g. from the SQL editor).
create function app_prj02.create_family(p_name text, p_country text, p_hours int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_family uuid;
  v_code   text := replace(gen_random_uuid()::text, '-', '');
begin
  if p_hours is null or p_hours not between 1 and 168 then
    raise exception 'invite hours must be between 1 and 168';
  end if;
  insert into app_prj02.families (name, country) values (btrim(p_name), upper(btrim(p_country)))
    returning id into v_family;
  insert into app_prj02.invites (family_id, code_hash, is_admin, expires_at)
    values (v_family, app_prj02.code_hash(v_code), true, now() + make_interval(hours => p_hours));
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', v_family, 'system', 'create_family', 'app_prj02.families', '{}'::jsonb);
  return jsonb_build_object('family_id', v_family, 'code', v_code);
end;
$$;

-- Forget me (CLAUDE.md "Forget me", rules 1-5). Lists every table that holds prj02 personal data;
-- a new such table is added here in the same pull request.
--   app rows: the person, with their contacts, consents and request contexts (cascade); invites
--             they created or used stay for the family but lose the link; a family left with no
--             person is deleted with everything in it (invites cascade)
--   core.audit_log: rows of a deleted family lose the link (tenant_id null, detail emptied); rows
--             naming the person as actor in a family that stays are anonymised
--   core.cost_ledger: rows of a deleted family lose the link
--   core.agent_runs: goal, steps and waiting_for emptied for a deleted family
--   the request is logged with counts only.
create function app_prj02.forget(p_person uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_family     uuid;
  v_last       boolean;
  n_people     int;
  n_contacts   int;
  n_consents   int;
  n_invites_u  int;
  n_invites    int := 0;
  n_families   int := 0;
  n_audit      int;
  n_cost       int := 0;
  n_runs       int := 0;
  v_counts     jsonb;
begin
  if p_person is null then
    raise exception 'no person given';
  end if;
  select family_id into v_family from app_prj02.people where id = p_person;
  v_last := v_family is not null
            and not exists (select 1 from app_prj02.people where family_id = v_family and id <> p_person);

  select count(*) into n_contacts from app_prj02.contacts where person_id = p_person;
  select count(*) into n_consents from app_prj02.consents where person_id = p_person;
  update app_prj02.invites set created_by = case when created_by = p_person then null else created_by end,
                               used_by    = case when used_by    = p_person then null else used_by end
   where created_by = p_person or used_by = p_person;
  get diagnostics n_invites_u = row_count;
  delete from app_prj02.people where id = p_person;
  get diagnostics n_people = row_count;

  if v_last then
    select count(*) into n_invites from app_prj02.invites where family_id = v_family;
    delete from app_prj02.families where id = v_family;
    get diagnostics n_families = row_count;
    update core.cost_ledger set tenant_id = null where app = 'prj02' and tenant_id = v_family;
    get diagnostics n_cost = row_count;
    update core.agent_runs set goal = '', steps = '[]'::jsonb, waiting_for = null, updated_at = now()
     where app = 'prj02' and tenant_id = v_family;
    get diagnostics n_runs = row_count;
  end if;

  update core.audit_log
     set tenant_id = case when v_last then null else tenant_id end,
         detail    = case when v_last or actor = p_person::text then '{}'::jsonb else detail end,
         actor     = case when actor = p_person::text then 'forgotten' else actor end
   where app = 'prj02' and ((v_last and tenant_id = v_family) or actor = p_person::text);
  get diagnostics n_audit = row_count;

  v_counts := jsonb_build_object(
    'app_prj02.people', n_people, 'app_prj02.contacts', n_contacts, 'app_prj02.consents', n_consents,
    'app_prj02.invites_unlinked', n_invites_u, 'app_prj02.invites', n_invites,
    'app_prj02.families', n_families, 'core.audit_log', n_audit, 'core.cost_ledger', n_cost,
    'core.agent_runs', n_runs);
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', null, 'system', 'forget', null, v_counts);
  return v_counts;
end;
$$;

-- The person in the current request forgets themselves (/forgetme in the bot).
create function app_prj02.forget_me() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_person uuid := app_prj02.current_person();
begin
  if v_person is null then
    raise exception 'no request context' using errcode = '42501';
  end if;
  return app_prj02.forget(v_person);
end;
$$;

-- Grants.
revoke all on schema app_prj02 from public, anon, authenticated;
revoke all on all tables in schema app_prj02 from public, anon, authenticated;
revoke execute on all functions in schema app_prj02 from public, anon, authenticated;

grant usage on schema app_prj02 to app_prj02_bot;
grant select on app_prj02.families, app_prj02.people, app_prj02.contacts, app_prj02.consents,
  app_prj02.invites to app_prj02_bot;
grant execute on function app_prj02.is_member(uuid), app_prj02.current_person(),
  app_prj02.begin_request(text, text), app_prj02.preview_invite(text),
  app_prj02.accept_invite(text, text, text, text, text), app_prj02.record_consent(text),
  app_prj02.create_invite(int, boolean), app_prj02.note_refusal(text), app_prj02.forget_me()
  to app_prj02_bot;
-- create_family(), forget() and code_hash(): owner only.
