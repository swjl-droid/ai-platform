-- ai-platform: Family calendar link and calendar change log of prj02 (Family orchestrator), story
-- prj02-R1 US-2 (calendar changes by chat).
-- Applied 27/11/2026 after John's "yes, apply"; file named from the recorded version (CLAUDE.md rule 3).
--
-- Decisions: the bot reaches each family's shared calendar through a Google service account the
-- family shares its calendar with (27/11/2026, Hub decision 'Bot reaches the Family calendar
-- through a shared service account'); a calendar change is written only after the yes of the adult
-- who asked (US-2, L1 in Hub row 128), and waits meanwhile as a core.agent_runs row with status
-- waiting_approval (ADR-02).
--
-- Flow, one change: propose_change() stores the proposal and opens the run (waiting_approval);
-- the adult taps Yes or No; decide_change() checks it is the same adult, in time, and marks the
-- change approved (run running) or declined (run cancelled); the app writes to Google; then
-- record_result() marks it applied or failed (run done or failed). Every step is in the log.
--
-- Separation rule: both tables carry family_id, RLS through app_prj02.is_member(); composite
-- foreign keys tie a change to a person of the same family.
--
-- Who may do what:
--   anon, authenticated  nothing
--   app_prj02_bot        read its family's calendar link and change log; propose, decide and
--                        record changes only through the functions below
--   owner (postgres)     set_calendar() for a family (after the family shares its calendar)
-- forget(): replaced below to clear the new tables too.

create table app_prj02.calendars (
  id           uuid primary key default gen_random_uuid(),
  family_id    uuid not null references app_prj02.families (id) on delete cascade,
  provider     text not null default 'google' check (provider in ('google')),
  external_id  text not null check (length(external_id) between 3 and 200),
  time_zone    text not null default 'Asia/Singapore' check (length(time_zone) between 3 and 60),
  created_at   timestamptz not null default now(),
  unique (family_id, provider)
);
comment on table app_prj02.calendars is 'the shared calendar of each family (release 1: one Google calendar); external_id is its calendar id';

create table app_prj02.calendar_changes (
  id           uuid primary key default gen_random_uuid(),
  family_id    uuid not null references app_prj02.families (id) on delete cascade,
  person_id    uuid,
  run_id       uuid not null,
  action       text not null check (action in ('add', 'move', 'cancel')),
  event_id     text check (event_id is null or length(event_id) between 1 and 1024),
  proposal     jsonb not null,
  status       text not null default 'proposed'
               check (status in ('proposed', 'approved', 'applied', 'declined', 'expired', 'failed')),
  error        text check (error is null or error ~ '^[a-z0-9_]{1,40}$'),
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null,
  decided_at   timestamptz,
  applied_at   timestamptz,
  foreign key (person_id, family_id) references app_prj02.people (id, family_id) on delete set null (person_id)
);
create index calendar_changes_family on app_prj02.calendar_changes (family_id, created_at desc);
comment on table app_prj02.calendar_changes is 'log of every calendar change asked by chat: who asked (person_id, emptied by forget), what, and what happened';

alter table app_prj02.calendars        enable row level security;
alter table app_prj02.calendar_changes enable row level security;
create policy calendars_read on app_prj02.calendars for select to app_prj02_bot using (app_prj02.is_member(family_id));
create policy calendar_changes_read on app_prj02.calendar_changes for select to app_prj02_bot using (app_prj02.is_member(family_id));

-- The owner links a family to the calendar it shared with the bot (one per provider).
create function app_prj02.set_calendar(p_family uuid, p_external_id text, p_time_zone text default 'Asia/Singapore')
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  insert into app_prj02.calendars (family_id, provider, external_id, time_zone)
    values (p_family, 'google', btrim(p_external_id), p_time_zone)
  on conflict (family_id, provider) do update set external_id = excluded.external_id, time_zone = excluded.time_zone
  returning id into v_id;
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', p_family, 'system', 'set_calendar', 'app_prj02.calendars', '{}'::jsonb);
  return v_id;
end;
$$;

-- A proposed change from the adult in the current request; waits for their yes.
create function app_prj02.propose_change(p_action text, p_event_id text, p_proposal jsonb, p_valid_minutes int)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  r      record;
  v_run  uuid;
  v_id   uuid := gen_random_uuid();
begin
  select person_id, family_id into r from app_prj02.request_ctx
   where xact = pg_catalog.pg_current_xact_id_if_assigned();
  if not found then raise exception 'no request context' using errcode = '42501'; end if;
  if p_valid_minutes is null or p_valid_minutes not between 1 and 1440 then
    raise exception 'valid minutes must be between 1 and 1440';
  end if;
  if jsonb_typeof(p_proposal) is distinct from 'object' then
    raise exception 'proposal must be a json object';
  end if;
  insert into core.agent_runs (app, tenant_id, goal, status, steps, step_count, waiting_for)
    values ('prj02', r.family_id, 'calendar_change', 'waiting_approval',
            jsonb_build_array(jsonb_build_object('step', 'propose', 'action', p_action)), 1,
            jsonb_build_object('change_id', v_id, 'person_id', r.person_id))
    returning id into v_run;
  insert into app_prj02.calendar_changes (id, family_id, person_id, run_id, action, event_id, proposal, expires_at)
    values (v_id, r.family_id, r.person_id, v_run, p_action, p_event_id, p_proposal,
            now() + make_interval(mins => p_valid_minutes));
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', r.family_id, r.person_id::text, 'calendar_propose', 'app_prj02.calendar_changes',
            jsonb_build_object('action', p_action));
  return v_id;
end;
$$;

-- Yes or No from the adult in the current request. Only the adult who asked can decide, only while
-- the proposal is open. Returns what to write on a yes.
create function app_prj02.decide_change(p_change uuid, p_yes boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  r  record;
  c  app_prj02.calendar_changes;
begin
  select person_id, family_id into r from app_prj02.request_ctx
   where xact = pg_catalog.pg_current_xact_id_if_assigned();
  if not found then raise exception 'no request context' using errcode = '42501'; end if;
  select * into c from app_prj02.calendar_changes where id = p_change and family_id = r.family_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown'); end if;
  if c.person_id is distinct from r.person_id then return jsonb_build_object('ok', false, 'reason', 'not_yours'); end if;
  if c.status <> 'proposed' then return jsonb_build_object('ok', false, 'reason', c.status); end if;
  if c.expires_at <= now() then
    update app_prj02.calendar_changes set status = 'expired', decided_at = now() where id = c.id;
    update core.agent_runs set status = 'cancelled', waiting_for = null, updated_at = now() where id = c.run_id;
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;
  update app_prj02.calendar_changes set status = case when p_yes then 'approved' else 'declined' end,
         decided_at = now() where id = c.id;
  update core.agent_runs
     set status = case when p_yes then 'running' else 'cancelled' end, waiting_for = null,
         steps = steps || jsonb_build_array(jsonb_build_object('step', case when p_yes then 'yes' else 'no' end)),
         step_count = step_count + 1, updated_at = now()
   where id = c.run_id;
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', r.family_id, r.person_id::text, case when p_yes then 'calendar_yes' else 'calendar_no' end,
            'app_prj02.calendar_changes', jsonb_build_object('action', c.action));
  if not p_yes then return jsonb_build_object('ok', true, 'status', 'declined'); end if;
  return jsonb_build_object('ok', true, 'status', 'approved', 'action', c.action, 'event_id', c.event_id,
                            'proposal', c.proposal, 'run_id', c.run_id);
end;
$$;

-- What happened when the app wrote the approved change to the calendar (error = kind only).
create function app_prj02.record_result(p_change uuid, p_ok boolean, p_event_id text, p_error text)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  r  record;
  c  app_prj02.calendar_changes;
begin
  select person_id, family_id into r from app_prj02.request_ctx
   where xact = pg_catalog.pg_current_xact_id_if_assigned();
  if not found then raise exception 'no request context' using errcode = '42501'; end if;
  select * into c from app_prj02.calendar_changes
   where id = p_change and family_id = r.family_id and status = 'approved' for update;
  if not found then return false; end if;
  update app_prj02.calendar_changes
     set status = case when p_ok then 'applied' else 'failed' end,
         event_id = coalesce(p_event_id, event_id),
         error = case when p_ok then null else coalesce(p_error, 'unknown') end,
         applied_at = case when p_ok then now() end
   where id = c.id;
  update core.agent_runs
     set status = case when p_ok then 'done' else 'failed' end,
         steps = steps || jsonb_build_array(jsonb_build_object('step', 'write', 'ok', p_ok)),
         step_count = step_count + 1, updated_at = now()
   where id = c.run_id;
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', r.family_id, r.person_id::text, 'calendar_' || case when p_ok then 'applied' else 'failed' end,
            'app_prj02.calendar_changes', jsonb_build_object('action', c.action));
  return true;
end;
$$;

-- Forget me, replaced to cover the new tables (CLAUDE.md "Forget me"; first version in
-- 20261127005951_prj02_tenancy.sql). Added:
--   app_prj02.calendar_changes: the person's link is removed (person_id null) when the family
--             stays; deleted with the family otherwise (cascade, counted)
--   app_prj02.calendars: deleted with the family (cascade, counted)
--   core.agent_runs: a run still waiting for the person's yes loses that link (waiting_for null)
create or replace function app_prj02.forget(p_person uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_family     uuid;
  v_last       boolean;
  n_people     int;
  n_contacts   int;
  n_consents   int;
  n_invites_u  int;
  n_changes_u  int;
  n_invites    int := 0;
  n_changes    int := 0;
  n_calendars  int := 0;
  n_families   int := 0;
  n_audit      int;
  n_cost       int := 0;
  n_runs       int := 0;
  n_waiting    int;
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
  update app_prj02.calendar_changes set person_id = null where person_id = p_person;
  get diagnostics n_changes_u = row_count;
  update core.agent_runs set waiting_for = null, updated_at = now()
   where app = 'prj02' and waiting_for ->> 'person_id' = p_person::text;
  get diagnostics n_waiting = row_count;
  delete from app_prj02.people where id = p_person;
  get diagnostics n_people = row_count;

  if v_last then
    select count(*) into n_invites from app_prj02.invites where family_id = v_family;
    select count(*) into n_changes from app_prj02.calendar_changes where family_id = v_family;
    select count(*) into n_calendars from app_prj02.calendars where family_id = v_family;
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
    'app_prj02.calendar_changes_unlinked', n_changes_u, 'app_prj02.calendar_changes', n_changes,
    'app_prj02.calendars', n_calendars, 'app_prj02.families', n_families,
    'core.audit_log', n_audit, 'core.cost_ledger', n_cost, 'core.agent_runs', n_runs,
    'core.agent_runs_unlinked', n_waiting);
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', null, 'system', 'forget', null, v_counts);
  return v_counts;
end;
$$;

-- Grants.
revoke all on app_prj02.calendars, app_prj02.calendar_changes from public, anon, authenticated;
revoke execute on function app_prj02.set_calendar(uuid, text, text), app_prj02.propose_change(text, text, jsonb, int),
  app_prj02.decide_change(uuid, boolean), app_prj02.record_result(uuid, boolean, text, text),
  app_prj02.forget(uuid) from public, anon, authenticated;
grant select on app_prj02.calendars, app_prj02.calendar_changes to app_prj02_bot;
grant execute on function app_prj02.propose_change(text, text, jsonb, int), app_prj02.decide_change(uuid, boolean),
  app_prj02.record_result(uuid, boolean, text, text) to app_prj02_bot;
-- set_calendar() and forget(): owner only.
