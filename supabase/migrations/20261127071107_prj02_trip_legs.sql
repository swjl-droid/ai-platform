-- prj02-R1 US-6 (third clash option and stay rule), decisions 27/11/2026 Hub rows 282 and 283.
--
-- Plain English:
--   Stay rule: events at the same place that follow each other (school day, then violin, then
--   tennis at UWC) are one stay: a drop-off only before the first, a pick-up only after the last.
--   The scheduler works this out in code and marks each trip's drop-off and pick-up as needed or not.
--   Own plan: under a clash message an adult taps "My own plan…", writes it in plain words ("no
--   drop off needed, only 1 pickup at 6pm"); the bot shows the plan; only that adult's Yes applies it.
--
-- Changes:
--   trips: drop_needed, pick_needed (stay rule, written by the scheduler); drop_mode, pick_mode
--     ('none' = the adult said this leg is not needed); pick_at (pick-up time set by the adult)
--   app_prj02.trip_plans (new): an adult's own plan for a clash, waiting for their words, then for
--     their Yes (person_id: deleted with the person; counted by forget())
--   job_upsert_trip(): takes drop_needed and pick_needed (default true, so the running code works);
--     a reminder for a leg that is no longer needed is skipped
--   assign_trips(): reminders only for the legs needed
--   bot functions: plan_await(), plan_pending(), plan_propose(), plan_decide() (only the adult who
--     wrote the plan, within its time)
--   forget(): replaced to count trip_plans
--
-- Grants: app_prj02_bot may run the four plan functions; app_prj02_job the new job_upsert_trip();
-- trip_plans is read by nobody directly (policy using false; functions only); anon and authenticated
-- nothing.

alter table app_prj02.trips
  add column drop_needed boolean not null default true,
  add column pick_needed boolean not null default true,
  add column drop_mode   text check (drop_mode is null or drop_mode = 'none'),
  add column pick_mode   text check (pick_mode is null or pick_mode = 'none'),
  add column pick_at     timestamptz;

create table app_prj02.trip_plans (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references app_prj02.families (id) on delete cascade,
  person_id   uuid not null,
  clash_id    uuid not null references app_prj02.reminders (id) on delete cascade,
  status      text not null default 'awaiting' check (status in ('awaiting', 'proposed', 'applied', 'declined', 'expired')),
  proposal    jsonb not null default '[]'::jsonb,
  expires_at  timestamptz not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  foreign key (person_id, family_id) references app_prj02.people (id, family_id) on delete cascade
);
create index trip_plans_person on app_prj02.trip_plans (person_id, status);
comment on table app_prj02.trip_plans is 'an adult''s own plan for a clash (prj02-R1 US-6): awaiting their words, then their Yes; applied only by them';
alter table app_prj02.trip_plans enable row level security;
create policy trip_plans_none on app_prj02.trip_plans for select to app_prj02_bot using (false);

-- ---------- job role ----------

drop function app_prj02.job_upsert_trip(text, timestamptz, timestamptz, text, text, int, text, timestamptz, timestamptz, timestamptz, timestamptz);
create function app_prj02.job_upsert_trip(p_event_id text, p_start timestamptz, p_end timestamptz, p_title text,
  p_location text, p_drive_min int, p_drive_source text, p_drop_leave timestamptz, p_pick_leave timestamptz,
  p_drop_send timestamptz, p_pick_send timestamptz, p_drop_needed boolean default true, p_pick_needed boolean default true)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_family uuid := app_prj02.job_family(); v_id uuid;
begin
  insert into app_prj02.trips (family_id, event_id, event_start, event_end, title, location, drive_min, drive_source,
                               drop_leave_at, pick_leave_at, drop_send_at, pick_send_at, drop_needed, pick_needed)
    values (v_family, p_event_id, p_start, p_end, left(btrim(p_title), 200), left(btrim(p_location), 300), p_drive_min,
            p_drive_source, p_drop_leave, p_pick_leave, p_drop_send, p_pick_send, p_drop_needed, p_pick_needed)
  on conflict (family_id, event_id, event_start) do update set
    event_end = excluded.event_end, title = excluded.title, location = excluded.location,
    drive_min = excluded.drive_min, drive_source = excluded.drive_source,
    drop_leave_at = excluded.drop_leave_at, pick_leave_at = excluded.pick_leave_at,
    drop_send_at = excluded.drop_send_at, pick_send_at = excluded.pick_send_at,
    drop_needed = excluded.drop_needed, pick_needed = excluded.pick_needed,
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

-- ---------- bot: own plan for a clash ----------

-- "My own plan…" tapped under a clash message: the adult's next words are read as their plan.
create function app_prj02.plan_await(p_clash uuid, p_minutes int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r record; v_id uuid;
begin
  select * into r from app_prj02.request_adult();
  if not exists (select 1 from app_prj02.reminders where id = p_clash and family_id = r.family_id and kind = 'clash') then
    return jsonb_build_object('ok', false, 'reason', 'unknown');
  end if;
  update app_prj02.trip_plans set status = 'expired', updated_at = now()
   where person_id = r.person_id and status in ('awaiting', 'proposed');
  insert into app_prj02.trip_plans (family_id, person_id, clash_id, expires_at)
    values (r.family_id, r.person_id, p_clash, now() + make_interval(mins => least(greatest(p_minutes, 1), 120)))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'plan', v_id);
end;
$$;

-- The asking adult's plan in progress (awaiting their words or their Yes), with the clash's trips.
create function app_prj02.plan_pending() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r record; p record;
begin
  select * into r from app_prj02.request_adult();
  select tp.id, tp.status, tp.proposal, m.payload -> 'trips' as trips into p
    from app_prj02.trip_plans tp join app_prj02.reminders m on m.id = tp.clash_id
   where tp.person_id = r.person_id and tp.status in ('awaiting', 'proposed') and tp.expires_at > now()
   order by tp.created_at desc limit 1;
  if p.id is null then return null; end if;
  return jsonb_build_object('plan', p.id, 'status', p.status, 'proposal', p.proposal, 'trips', p.trips);
end;
$$;

-- The checked plan, shown to the adult with Yes / No.
create function app_prj02.plan_propose(p_plan uuid, p_proposal jsonb) returns boolean
language plpgsql security definer set search_path = '' as $$
declare r record; n int;
begin
  select * into r from app_prj02.request_adult();
  if jsonb_typeof(p_proposal) is distinct from 'array' or jsonb_array_length(p_proposal) not between 1 and 5 then
    return false;
  end if;
  update app_prj02.trip_plans set status = 'proposed', proposal = p_proposal, updated_at = now()
   where id = p_plan and person_id = r.person_id and status in ('awaiting', 'proposed') and expires_at > now();
  get diagnostics n = row_count;
  return n = 1;
end;
$$;

-- Yes or No of the adult who wrote the plan. Yes: each trip gets its owner and legs, and reminders
-- only for the legs needed; the other adults' open questions for these trips are closed.
-- proposal items: {trip, mode: adult|taxi|public, person (adult), drop: 'none'|null,
--                  pick: 'none'|null, pick_at, pick_leave, drop_send, pick_send}
create function app_prj02.plan_decide(p_plan uuid, p_yes boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r record; p app_prj02.trip_plans; c jsonb; t app_prj02.trips; v_who uuid; n int := 0;
begin
  select * into r from app_prj02.request_adult();
  select * into p from app_prj02.trip_plans where id = p_plan and family_id = r.family_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown'); end if;
  if p.person_id is distinct from r.person_id then return jsonb_build_object('ok', false, 'reason', 'not_yours'); end if;
  if p.status <> 'proposed' then return jsonb_build_object('ok', false, 'reason', p.status); end if;
  if p.expires_at <= now() then
    update app_prj02.trip_plans set status = 'expired', updated_at = now() where id = p.id;
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;
  if not p_yes then
    update app_prj02.trip_plans set status = 'declined', updated_at = now() where id = p.id;
    return jsonb_build_object('ok', true, 'status', 'declined');
  end if;
  for c in select * from jsonb_array_elements(p.proposal) loop
    select * into t from app_prj02.trips where id = (c ->> 'trip')::uuid and family_id = r.family_id for update;
    if not found or t.status = 'cancelled' then raise exception 'plan names an unknown trip' using errcode = '22023'; end if;
    if c ->> 'mode' = 'adult' then
      v_who := (c ->> 'person')::uuid;
      if not exists (select 1 from app_prj02.people where id = v_who and family_id = r.family_id and role = 'adult') then
        raise exception 'plan names someone outside the family' using errcode = '22023';
      end if;
    elsif c ->> 'mode' in ('taxi', 'public') then
      v_who := r.person_id;
    else
      raise exception 'plan has a bad way of travel' using errcode = '22023';
    end if;
    update app_prj02.trips set status = 'assigned', owner_mode = c ->> 'mode',
           owner_person_id = case when c ->> 'mode' = 'adult' then v_who end,
           drop_mode = case when c ->> 'drop' = 'none' then 'none' end,
           pick_mode = case when c ->> 'pick' = 'none' then 'none' end,
           pick_at = nullif(c ->> 'pick_at', '')::timestamptz,
           pick_leave_at = coalesce(nullif(c ->> 'pick_leave', '')::timestamptz, pick_leave_at),
           pick_send_at = coalesce(nullif(c ->> 'pick_send', '')::timestamptz, pick_send_at),
           assigned_by = r.person_id, assigned_at = now(), updated_at = now()
     where id = t.id
    returning * into t;
    delete from app_prj02.reminders where trip_id = t.id and kind in ('drop', 'pick') and status = 'due';
    insert into app_prj02.reminders (family_id, trip_id, person_id, kind, send_at)
      select r.family_id, t.id, v_who, l.kind, l.send_at
        from (values ('drop', t.drop_send_at, t.drop_needed and t.drop_mode is null),
                     ('pick', t.pick_send_at, t.pick_needed and t.pick_mode is null)) as l (kind, send_at, needed)
       where l.needed
    on conflict (trip_id, kind, person_id) do update set send_at = excluded.send_at, status = 'due', sent_at = null;
    update app_prj02.reminders set status = 'skipped' where trip_id = t.id and kind in ('plan', 'clash') and status = 'due';
    n := n + 1;
  end loop;
  update app_prj02.trip_plans set status = 'applied', updated_at = now() where id = p.id;
  update app_prj02.family_settings set last_scan_at = null where family_id = r.family_id;
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', r.family_id, r.person_id::text, 'plan_applied', 'app_prj02.trips', jsonb_build_object('trips', n));
  return jsonb_build_object('ok', true, 'status', 'applied', 'trips', n);
end;
$$;

-- ---------- bot: a tap follows the needed legs ----------

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
    -- A tap is the standard plan: legs back to normal; reminders only for the legs needed
    -- (the stay rule may make a drop-off or pick-up unneeded, Hub row 283).
    update app_prj02.trips set drop_mode = null, pick_mode = null, pick_at = null where id = t.id;
    insert into app_prj02.reminders (family_id, trip_id, person_id, kind, send_at)
      select r.family_id, t.id, v_who, l.kind, l.send_at
        from (values ('drop', t.drop_send_at, t.drop_needed), ('pick', t.pick_send_at, t.pick_needed)) as l (kind, send_at, needed)
       where l.needed
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
-- Replaced to count app_prj02.trip_plans (the person's own plans).
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
    'app_prj02.families', n_families,
    'core.audit_log', n_audit, 'core.cost_ledger', n_cost, 'core.agent_runs', n_runs,
    'core.agent_runs_unlinked', n_waiting);
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', null, 'system', 'forget', null, v_counts);
  return v_counts;
end;
$$;

-- ---------- grants ----------
revoke all on app_prj02.trip_plans from public, anon, authenticated;
revoke execute on all functions in schema app_prj02 from public, anon, authenticated;
grant execute on function app_prj02.job_upsert_trip(text, timestamptz, timestamptz, text, text, int, text,
  timestamptz, timestamptz, timestamptz, timestamptz, boolean, boolean) to app_prj02_job;
grant execute on function app_prj02.plan_await(uuid, int), app_prj02.plan_pending(), app_prj02.plan_propose(uuid, jsonb),
  app_prj02.plan_decide(uuid, boolean), app_prj02.assign_trips(jsonb) to app_prj02_bot;
-- forget(): owner only.
