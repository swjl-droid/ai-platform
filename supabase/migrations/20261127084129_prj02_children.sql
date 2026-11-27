-- prj02-R1 US-7 (who each event is for), decision 27/11/2026 Hub row 298, from gap Hub row 290.
--
-- Plain English: each family says how its calendar names a child (John: "[event] - [child]",
-- e.g. "Ballet @ River - Cel"), and lists its children with the names they go by (nickname, short
-- name, full name). The scheduler then knows which child each event is for: an event naming no
-- child is an adult's own and not a trip; a name it does not know is asked once; stays and clashes
-- are worked out per child.
--
-- Changes:
--   app_prj02.children (new): the family's children, a name and up to 10 aliases each. Personal data
--     of children (names the adults enter): family key, deleted with the family, counted by forget();
--     children never use the bot (Hub rows 127 and 155).
--   app_prj02.calendar_conventions (new): one row per family (person_id null) or, later, per adult:
--     kind 'suffix' with a separator (' - '). Existing families get John's convention as default.
--   trips: child_ids, who_state (child / unknown / none_by_adult), unknown_name (the name asked about)
--   reminders: kinds 'unknown' (who is this?) and 'double' (one child in two places at once)
--   job_upsert_trip(): takes child_ids, who_state, unknown_name (defaults keep the running code working)
--   bot functions (the adult of the current request): child_save(), child_remove(), resolve_unknown()
--   set_family_settings(): also gives a family the default convention; set_convention() owner only
--   forget(): counts children and calendar_conventions (deleted with the family)
--
-- Grants: app_prj02_bot reads children and calendar_conventions of its family (RLS) and runs the three
-- functions; app_prj02_job reads both of its job family and runs the new job_upsert_trip(); anon and
-- authenticated nothing.

create table app_prj02.children (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references app_prj02.families (id) on delete cascade,
  name        text not null check (length(btrim(name)) between 1 and 60),
  aliases     text[] not null default '{}' check (cardinality(aliases) <= 10),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (id, family_id)
);
create unique index children_family_name on app_prj02.children (family_id, lower(name));
comment on table app_prj02.children is 'the family''s children (names and aliases the adults enter) so the bot knows who an event is for; children never use the bot';

create table app_prj02.calendar_conventions (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references app_prj02.families (id) on delete cascade,
  person_id   uuid,
  kind        text not null default 'suffix' check (kind in ('suffix')),
  separator   text not null default ' - ' check (length(separator) between 1 and 5),
  created_at  timestamptz not null default now(),
  foreign key (person_id, family_id) references app_prj02.people (id, family_id) on delete cascade
);
create unique index calendar_conventions_one on app_prj02.calendar_conventions (family_id, coalesce(person_id, '00000000-0000-0000-0000-000000000000'::uuid));
comment on table app_prj02.calendar_conventions is 'how a family (or, later, one adult) names the child in a calendar event title: kind suffix = "[event]<separator>[child]"';

alter table app_prj02.children enable row level security;
alter table app_prj02.calendar_conventions enable row level security;
create policy children_read on app_prj02.children for select to app_prj02_bot using (app_prj02.is_member(family_id));
create policy calendar_conventions_read on app_prj02.calendar_conventions for select to app_prj02_bot using (app_prj02.is_member(family_id));
create policy job_children_read on app_prj02.children for select to app_prj02_job using (app_prj02.is_member(family_id));
create policy job_calendar_conventions_read on app_prj02.calendar_conventions for select to app_prj02_job using (app_prj02.is_member(family_id));

insert into app_prj02.calendar_conventions (family_id, person_id, kind, separator)
select s.family_id, null, 'suffix', ' - ' from app_prj02.family_settings s
on conflict do nothing;

alter table app_prj02.trips
  add column child_ids    uuid[] not null default '{}',
  add column who_state    text not null default 'child' check (who_state in ('child', 'unknown', 'none_by_adult')),
  add column unknown_name text check (unknown_name is null or length(unknown_name) <= 60);

alter table app_prj02.reminders drop constraint reminders_kind_check;
alter table app_prj02.reminders add constraint reminders_kind_check
  check (kind in ('plan', 'clash', 'drop', 'pick', 'warning', 'unknown', 'double'));

-- job_queue(): also 'unknown' and 'double' questions (none while paused).
create or replace function app_prj02.job_queue(p_trip uuid, p_kind text, p_person uuid, p_send_at timestamptz, p_payload jsonb)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_family uuid := app_prj02.job_family(); n int;
begin
  if p_kind not in ('plan', 'clash', 'warning', 'unknown', 'double') then
    raise exception 'the job queues only plan, clash, warning, unknown and double messages';
  end if;
  if exists (select 1 from app_prj02.family_settings where family_id = v_family and paused_at is not null) then
    return false; -- paused: nothing new is queued
  end if;
  insert into app_prj02.reminders (family_id, trip_id, person_id, kind, send_at, payload)
    values (v_family, p_trip, p_person, p_kind, p_send_at, coalesce(p_payload, '{}'::jsonb))
  on conflict (trip_id, kind, person_id) do nothing;
  get diagnostics n = row_count;
  return n = 1;
end;
$$;

-- ---------- job role ----------

drop function app_prj02.job_upsert_trip(text, timestamptz, timestamptz, text, text, int, text, timestamptz, timestamptz,
  timestamptz, timestamptz, boolean, boolean);
create function app_prj02.job_upsert_trip(p_event_id text, p_start timestamptz, p_end timestamptz, p_title text,
  p_location text, p_drive_min int, p_drive_source text, p_drop_leave timestamptz, p_pick_leave timestamptz,
  p_drop_send timestamptz, p_pick_send timestamptz, p_drop_needed boolean default true, p_pick_needed boolean default true,
  p_child_ids uuid[] default '{}', p_who_state text default 'child', p_unknown_name text default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_family uuid := app_prj02.job_family(); v_id uuid;
begin
  insert into app_prj02.trips (family_id, event_id, event_start, event_end, title, location, drive_min, drive_source,
                               drop_leave_at, pick_leave_at, drop_send_at, pick_send_at, drop_needed, pick_needed,
                               child_ids, who_state, unknown_name)
    values (v_family, p_event_id, p_start, p_end, left(btrim(p_title), 200), left(btrim(p_location), 300), p_drive_min,
            p_drive_source, p_drop_leave, p_pick_leave, p_drop_send, p_pick_send, p_drop_needed, p_pick_needed,
            coalesce(p_child_ids, '{}'), p_who_state, left(btrim(p_unknown_name), 60))
  on conflict (family_id, event_id, event_start) do update set
    event_end = excluded.event_end, title = excluded.title, location = excluded.location,
    drive_min = excluded.drive_min, drive_source = excluded.drive_source,
    drop_leave_at = excluded.drop_leave_at, pick_leave_at = excluded.pick_leave_at,
    drop_send_at = excluded.drop_send_at, pick_send_at = excluded.pick_send_at,
    drop_needed = excluded.drop_needed, pick_needed = excluded.pick_needed,
    child_ids = excluded.child_ids,
    -- An adult's answer ('not a child') is kept; otherwise the scan decides.
    who_state = case when app_prj02.trips.who_state = 'none_by_adult' then 'none_by_adult' else excluded.who_state end,
    unknown_name = excluded.unknown_name,
    status = case when app_prj02.trips.status = 'cancelled' then 'open' else app_prj02.trips.status end,
    updated_at = now()
  returning id into v_id;
  update app_prj02.reminders r set send_at = case r.kind when 'drop' then p_drop_send else p_pick_send end
   where r.trip_id = v_id and r.status = 'due' and r.kind in ('drop', 'pick');
  -- A leg the stay rule no longer needs gets no reminder.
  update app_prj02.reminders r set status = 'skipped'
   where r.trip_id = v_id and r.status = 'due'
     and ((r.kind = 'drop' and not p_drop_needed) or (r.kind = 'pick' and not p_pick_needed));
  return v_id;
end;
$$;

-- ---------- bot (the adult of the current request) ----------

-- Adds or updates a child by name (case does not matter), with its aliases.
create function app_prj02.child_save(p_name text, p_aliases text[]) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r record; v_id uuid; v_aliases text[];
begin
  select * into r from app_prj02.request_adult();
  if p_name is null or length(btrim(p_name)) not between 1 and 60 then return jsonb_build_object('ok', false, 'reason', 'bad_name'); end if;
  select coalesce(array_agg(distinct left(btrim(a), 60)) filter (where length(btrim(a)) between 1 and 60), '{}') into v_aliases
    from unnest(coalesce(p_aliases, '{}')) as a;
  if cardinality(v_aliases) > 10 then return jsonb_build_object('ok', false, 'reason', 'too_many'); end if;
  insert into app_prj02.children (family_id, name, aliases) values (r.family_id, btrim(p_name), v_aliases)
  on conflict (family_id, (lower(name))) do update set aliases = excluded.aliases, updated_at = now()
  returning id into v_id;
  update app_prj02.family_settings set last_scan_at = null where family_id = r.family_id;
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', r.family_id, r.person_id::text, 'child_save', 'app_prj02.children', jsonb_build_object('aliases', cardinality(v_aliases)));
  return jsonb_build_object('ok', true, 'child', v_id);
end;
$$;

create function app_prj02.child_remove(p_name text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r record; n int;
begin
  select * into r from app_prj02.request_adult();
  delete from app_prj02.children where family_id = r.family_id and lower(name) = lower(btrim(p_name));
  get diagnostics n = row_count;
  if n = 0 then return jsonb_build_object('ok', false, 'reason', 'unknown'); end if;
  update app_prj02.family_settings set last_scan_at = null where family_id = r.family_id;
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', r.family_id, r.person_id::text, 'child_remove', 'app_prj02.children', '{}'::jsonb);
  return jsonb_build_object('ok', true);
end;
$$;

-- Answer to "who is X?": the name becomes an alias of that child, or (no child) the event is an
-- adult's own and not a trip.
create function app_prj02.resolve_unknown(p_trip uuid, p_child uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r record; t app_prj02.trips;
begin
  select * into r from app_prj02.request_adult();
  select * into t from app_prj02.trips where id = p_trip and family_id = r.family_id and who_state = 'unknown';
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown'); end if;
  if p_child is not null then
    update app_prj02.children set aliases = (select array_agg(distinct a) from unnest(aliases || t.unknown_name) as a),
           updated_at = now()
     where id = p_child and family_id = r.family_id and cardinality(aliases) < 10 and t.unknown_name is not null;
    if not found then return jsonb_build_object('ok', false, 'reason', 'bad_child'); end if;
    update app_prj02.trips set who_state = 'child', child_ids = array[p_child], updated_at = now() where id = t.id;
  else
    update app_prj02.trips set who_state = 'none_by_adult', updated_at = now() where id = t.id;
  end if;
  update app_prj02.reminders set status = 'skipped' where trip_id = t.id and kind = 'unknown' and status = 'due';
  update app_prj02.family_settings set last_scan_at = null where family_id = r.family_id;
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', r.family_id, r.person_id::text, 'resolve_unknown', 'app_prj02.trips',
            jsonb_build_object('as_child', p_child is not null));
  return jsonb_build_object('ok', true, 'as_child', p_child is not null);
end;
$$;

-- ---------- owner ----------

create or replace function app_prj02.set_family_settings(p_family uuid, p_home_postal text, p_cars int) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into app_prj02.family_settings (family_id, home_postal, cars)
    values (p_family, nullif(btrim(p_home_postal), ''), p_cars)
  on conflict (family_id) do update set home_postal = excluded.home_postal, cars = excluded.cars,
    home_lat = case when app_prj02.family_settings.home_postal is distinct from excluded.home_postal then null else app_prj02.family_settings.home_lat end,
    home_lng = case when app_prj02.family_settings.home_postal is distinct from excluded.home_postal then null else app_prj02.family_settings.home_lng end,
    updated_at = now();
  insert into app_prj02.travel_modes (family_id, mode, route, estimate_min, lead_min)
    values (p_family, 'car', 'drive', 30, 0), (p_family, 'taxi', 'drive', 30, 10), (p_family, 'public', 'pt', 60, 0)
  on conflict do nothing;
  insert into app_prj02.calendar_conventions (family_id, person_id, kind, separator)
    values (p_family, null, 'suffix', ' - ')
  on conflict do nothing;
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', p_family, 'system', 'set_family_settings', 'app_prj02.family_settings', jsonb_build_object('cars', p_cars));
end;
$$;

create function app_prj02.set_convention(p_family uuid, p_person uuid, p_kind text, p_separator text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from app_prj02.calendar_conventions where family_id = p_family and person_id is not distinct from p_person;
  insert into app_prj02.calendar_conventions (family_id, person_id, kind, separator) values (p_family, p_person, p_kind, p_separator);
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', p_family, 'system', 'set_convention', 'app_prj02.calendar_conventions', jsonb_build_object('kind', p_kind));
end;
$$;

-- ---------- forget ----------
-- Replaced to count app_prj02.children and app_prj02.calendar_conventions (deleted with the family).
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
  n_trips_u    int;
  n_reminders  int;
  n_invites    int := 0;
  n_changes    int := 0;
  n_calendars  int := 0;
  n_trips      int := 0;
  n_places     int := 0;
  n_settings   int := 0;
  n_modes      int := 0;
  n_plans      int;
  n_children   int := 0;
  n_conv       int := 0;
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
  update app_prj02.trips set owner_person_id = case when owner_person_id = p_person then null else owner_person_id end,
                             assigned_by     = case when assigned_by = p_person then null else assigned_by end
   where owner_person_id = p_person or assigned_by = p_person;
  get diagnostics n_trips_u = row_count;
  delete from app_prj02.trip_plans where person_id = p_person;
  get diagnostics n_plans = row_count;
  delete from app_prj02.reminders where person_id = p_person;
  get diagnostics n_reminders = row_count;
  update core.agent_runs set waiting_for = null, updated_at = now()
   where app = 'prj02' and waiting_for ->> 'person_id' = p_person::text;
  get diagnostics n_waiting = row_count;
  delete from app_prj02.people where id = p_person;
  get diagnostics n_people = row_count;

  if v_last then
    select count(*) into n_invites from app_prj02.invites where family_id = v_family;
    select count(*) into n_changes from app_prj02.calendar_changes where family_id = v_family;
    select count(*) into n_calendars from app_prj02.calendars where family_id = v_family;
    select count(*) into n_trips from app_prj02.trips where family_id = v_family;
    select count(*) into n_places from app_prj02.places where family_id = v_family;
    select count(*) into n_settings from app_prj02.family_settings where family_id = v_family;
    select count(*) into n_modes from app_prj02.travel_modes where family_id = v_family;
    select count(*) into n_children from app_prj02.children where family_id = v_family;
    select count(*) into n_conv from app_prj02.calendar_conventions where family_id = v_family;
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
    'app_prj02.calendars', n_calendars, 'app_prj02.trips_unlinked', n_trips_u, 'app_prj02.trips', n_trips,
    'app_prj02.reminders', n_reminders, 'app_prj02.places', n_places, 'app_prj02.family_settings', n_settings,
    'app_prj02.travel_modes', n_modes, 'app_prj02.trip_plans', n_plans,
    'app_prj02.children', n_children, 'app_prj02.calendar_conventions', n_conv,
    'app_prj02.families', n_families,
    'core.audit_log', n_audit, 'core.cost_ledger', n_cost, 'core.agent_runs', n_runs,
    'core.agent_runs_unlinked', n_waiting);
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', null, 'system', 'forget', null, v_counts);
  return v_counts;
end;
$$;

-- ---------- grants ----------
revoke all on app_prj02.children, app_prj02.calendar_conventions from public, anon, authenticated;
revoke execute on all functions in schema app_prj02 from public, anon, authenticated;
grant select on app_prj02.children, app_prj02.calendar_conventions to app_prj02_bot, app_prj02_job;
grant execute on function app_prj02.job_upsert_trip(text, timestamptz, timestamptz, text, text, int, text, timestamptz,
  timestamptz, timestamptz, timestamptz, boolean, boolean, uuid[], text, text) to app_prj02_job;
grant execute on function app_prj02.child_save(text, text[]), app_prj02.child_remove(text), app_prj02.resolve_unknown(uuid, uuid)
  to app_prj02_bot;
-- set_family_settings(), set_convention() and forget(): owner only.
