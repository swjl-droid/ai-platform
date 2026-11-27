-- prj02-R1 US-3 (reminders and clashes): travel time per way of travel (decision 27/11/2026,
-- Hub row 277, option B with John's values).
--
-- Plain English: the bot used one guess (20 min) for every trip. Now each family has one row per
-- way of travel: how to ask OneMap (drive or public-transport route), the guess when OneMap cannot
-- tell, and a lead time (a taxi must be booked before it comes). A new way of travel is a new row.
--   car     drive route, else 30 min
--   taxi    drive route + 10 min booking lead, else 30 + 10 min
--   public  public-transport route, else 60 min
--
-- Changes:
--   app_prj02.travel_modes (new; family_id; no personal data; deleted with the family)
--   app_prj02.places: one saved time per place and route (column route; unique per family, place, route)
--   app_prj02.family_settings: default_drive_min removed (replaced by the 'car' row)
--   set_family_settings(): also gives a new family the three starting rows (kept if they exist)
--   set_travel_mode(): owner only, changes one row
--   job_save_place(): takes the route (default 'drive')
--   assign_trips(): after a tap, the next tick re-plans the family (leave times follow the way of travel)
--   forget(): counts travel_modes (deleted with the family)
--
-- Grants: app_prj02_job may read travel_modes of the family its job opened (RLS policy) and run the new
-- job_save_place(); app_prj02_bot gets nothing on travel_modes; anon and authenticated nothing;
-- set_family_settings(), set_travel_mode() and forget() stay owner only.

create table app_prj02.travel_modes (
  family_id     uuid not null references app_prj02.families (id) on delete cascade,
  mode          text not null check (mode in ('car', 'taxi', 'public')),
  route         text not null check (route in ('drive', 'pt', 'walk', 'cycle')),
  estimate_min  int  not null check (estimate_min between 1 and 240),
  lead_min      int  not null default 0 check (lead_min between 0 and 120),
  updated_at    timestamptz not null default now(),
  primary key (family_id, mode)
);
comment on table app_prj02.travel_modes is 'one row per way of travel of a family: OneMap route to ask, the estimate when OneMap cannot tell, lead time (taxi booking); trips owned by an adult use car';
alter table app_prj02.travel_modes enable row level security;
create policy job_travel_modes_read on app_prj02.travel_modes for select to app_prj02_job using (app_prj02.is_member(family_id));

-- Starting rows for every family that already has settings (decided values, Hub row 277).
insert into app_prj02.travel_modes (family_id, mode, route, estimate_min, lead_min)
select s.family_id, v.mode, v.route, v.estimate_min, v.lead_min
  from app_prj02.family_settings s
 cross join (values ('car', 'drive', 30, 0), ('taxi', 'drive', 30, 10), ('public', 'pt', 60, 0))
       as v (mode, route, estimate_min, lead_min)
on conflict do nothing;

alter table app_prj02.family_settings drop column default_drive_min;

-- Saved places: one time per route (a drive and a public-transport time for the same pool).
alter table app_prj02.places add column route text not null default 'drive' check (route in ('drive', 'pt', 'walk', 'cycle'));
alter table app_prj02.places drop constraint places_family_id_label_key_key;
alter table app_prj02.places add constraint places_family_route_key unique (family_id, label_key, route);

drop function app_prj02.job_save_place(text, double precision, double precision, int, text);
create function app_prj02.job_save_place(p_label_key text, p_lat double precision, p_lng double precision,
                                         p_drive_min int, p_source text, p_route text default 'drive') returns void
language sql security definer set search_path = '' as $$
  insert into app_prj02.places (family_id, label_key, lat, lng, drive_min, source, route)
    values (app_prj02.job_family(), lower(btrim(p_label_key)), p_lat, p_lng, p_drive_min, p_source, p_route)
  on conflict (family_id, label_key, route) do update set lat = excluded.lat, lng = excluded.lng,
    drive_min = excluded.drive_min, source = excluded.source, updated_at = now();
$$;

-- ---------- owner ----------

-- The starting rows are written with the family's settings, so a family set up later gets them too.
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
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', p_family, 'system', 'set_family_settings', 'app_prj02.family_settings', jsonb_build_object('cars', p_cars));
end;
$$;

create function app_prj02.set_travel_mode(p_family uuid, p_mode text, p_route text, p_estimate_min int, p_lead_min int)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into app_prj02.travel_modes (family_id, mode, route, estimate_min, lead_min)
    values (p_family, p_mode, p_route, p_estimate_min, coalesce(p_lead_min, 0))
  on conflict (family_id, mode) do update set route = excluded.route, estimate_min = excluded.estimate_min,
    lead_min = excluded.lead_min, updated_at = now();
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', p_family, 'system', 'set_travel_mode', 'app_prj02.travel_modes',
            jsonb_build_object('mode', p_mode, 'route', p_route, 'estimate_min', p_estimate_min, 'lead_min', coalesce(p_lead_min, 0)));
end;
$$;

-- ---------- bot: a tap re-plans the family ----------

create or replace function app_prj02.assign_trips(p_choices jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  r      record;
  c      jsonb;
  t      app_prj02.trips;
  v_who  uuid;
  n      int := 0;
begin
  select person_id, family_id into r from app_prj02.request_ctx
   where xact = pg_catalog.pg_current_xact_id_if_assigned() and kind = 'person';
  if not found then raise exception 'no request context' using errcode = '42501'; end if;
  if not exists (select 1 from app_prj02.people where id = r.person_id and role = 'adult') then
    return jsonb_build_object('ok', false, 'reason', 'not_adult');
  end if;
  if jsonb_typeof(p_choices) is distinct from 'array' or jsonb_array_length(p_choices) not between 1 and 5 then
    return jsonb_build_object('ok', false, 'reason', 'bad_choice');
  end if;
  for c in select * from jsonb_array_elements(p_choices) loop
    select * into t from app_prj02.trips
     where id = (c ->> 'trip')::uuid and family_id = r.family_id for update;
    if not found or t.status = 'cancelled' then return jsonb_build_object('ok', false, 'reason', 'unknown'); end if;
    if c ->> 'mode' = 'adult' then
      v_who := (c ->> 'person')::uuid;
      if not exists (select 1 from app_prj02.people where id = v_who and family_id = r.family_id and role = 'adult') then
        return jsonb_build_object('ok', false, 'reason', 'bad_choice');
      end if;
    elsif c ->> 'mode' in ('taxi', 'public') then
      v_who := r.person_id;
    else
      return jsonb_build_object('ok', false, 'reason', 'bad_choice');
    end if;
    update app_prj02.trips set status = 'assigned', owner_mode = c ->> 'mode',
           owner_person_id = case when c ->> 'mode' = 'adult' then v_who end,
           assigned_by = r.person_id, assigned_at = now(), updated_at = now()
     where id = t.id;
    delete from app_prj02.reminders where trip_id = t.id and kind in ('drop', 'pick') and status = 'due';
    insert into app_prj02.reminders (family_id, trip_id, person_id, kind, send_at)
      values (r.family_id, t.id, v_who, 'drop', t.drop_send_at), (r.family_id, t.id, v_who, 'pick', t.pick_send_at)
    on conflict (trip_id, kind, person_id) do update set send_at = excluded.send_at, status = 'due', sent_at = null;
    -- The other adults' open 'who takes it?' and clash messages for this trip are no longer needed.
    update app_prj02.reminders set status = 'skipped' where trip_id = t.id and kind in ('plan', 'clash') and status = 'due';
    n := n + 1;
  end loop;
  -- The way of travel sets the leave times (taxi booking lead, public transport route): the next
  -- tick re-plans this family's trips at once instead of at its next scan.
  if n > 0 then
    update app_prj02.family_settings set last_scan_at = null where family_id = r.family_id;
  end if;
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', r.family_id, r.person_id::text, 'assign_trips', 'app_prj02.trips', jsonb_build_object('trips', n));
  return jsonb_build_object('ok', true, 'assigned', n);
end;
$$;

-- ---------- forget ----------
-- Replaced to count app_prj02.travel_modes (deleted with the family; no personal data).
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
    'app_prj02.travel_modes', n_modes,
    'app_prj02.families', n_families,
    'core.audit_log', n_audit, 'core.cost_ledger', n_cost, 'core.agent_runs', n_runs,
    'core.agent_runs_unlinked', n_waiting);
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', null, 'system', 'forget', null, v_counts);
  return v_counts;
end;
$$;

-- ---------- grants ----------
revoke all on app_prj02.travel_modes from public, anon, authenticated;
revoke execute on all functions in schema app_prj02 from public, anon, authenticated;
grant select on app_prj02.travel_modes to app_prj02_job;
grant execute on function app_prj02.job_save_place(text, double precision, double precision, int, text, text) to app_prj02_job;
grant execute on function app_prj02.assign_trips(jsonb) to app_prj02_bot;
-- set_family_settings(), set_travel_mode() and forget(): owner only.
