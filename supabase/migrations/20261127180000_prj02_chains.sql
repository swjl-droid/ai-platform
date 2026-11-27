-- prj02-R1 US-8 (real clash days: chained trips, own times, different adults per leg), decision
-- 27/11/2026 Hub row 298, from gap Hub row 296 (design fix 1: one parent drops both children one
-- after the other, leaving earlier; Hub rows 106 and 110).
--
-- Plain English: each drop-off and pick-up can now have its own adult, its own way of travel, its
-- own leave time and a short note ("then Acro @ Dunearn"). That lets one adult do several stops
-- with one car (leave 14:45, Cel to River, Ang to Dunearn, wait, pick up Ang then Cel), lets an
-- adult say "leave at 14:45", and lets one adult drop off while another picks up.
--
-- Changes:
--   trips: drop_person, pick_person (the adult of each leg; unlinked by forget()); drop_leave_set,
--     pick_leave_set (leave times chosen by an adult or a chained plan: the scan keeps them);
--     drop_note, pick_note (what comes next on a chained trip); drop_mode / pick_mode also 'taxi' or
--     'public' (a leg by another way than the trip's owner)
--   legs_ok(): checks a choice's legs (adults of this family; times near the activity)
--   assign_trips(), plan_decide(): take the per-leg fields; reminders go to each leg's adult
--   plan_pending(): also returns the clash's drive time between the two places
--   forget(): unlinks the person from drop_person and pick_person too
--
-- Grants: unchanged for the bot (assign_trips, plan_decide, plan_pending keep their grants);
-- legs_ok() is internal (no grant); anon and authenticated nothing.

alter table app_prj02.trips
  add column drop_person    uuid,
  add column pick_person    uuid,
  add column drop_leave_set timestamptz,
  add column pick_leave_set timestamptz,
  add column drop_note      text check (drop_note is null or length(drop_note) <= 120),
  add column pick_note      text check (pick_note is null or length(pick_note) <= 120),
  add constraint trips_drop_person_fk foreign key (drop_person, family_id) references app_prj02.people (id, family_id) on delete set null (drop_person),
  add constraint trips_pick_person_fk foreign key (pick_person, family_id) references app_prj02.people (id, family_id) on delete set null (pick_person);
alter table app_prj02.trips drop constraint trips_drop_mode_check;
alter table app_prj02.trips drop constraint trips_pick_mode_check;
alter table app_prj02.trips add constraint trips_drop_mode_check check (drop_mode is null or drop_mode in ('none', 'taxi', 'public'));
alter table app_prj02.trips add constraint trips_pick_mode_check check (pick_mode is null or pick_mode in ('none', 'taxi', 'public'));

-- A choice's legs: each named adult is an adult of this family; a drop-off leave time is at most 4 h
-- before the start (and not after it); a pick-up leave time is between the start and 4 h after the end.
create function app_prj02.legs_ok(c jsonb, t app_prj02.trips, p_family uuid) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare v uuid; v_drop timestamptz; v_pick timestamptz;
begin
  foreach v in array array[nullif(c ->> 'drop_person', '')::uuid, nullif(c ->> 'pick_person', '')::uuid] loop
    if v is not null and not exists (select 1 from app_prj02.people where id = v and family_id = p_family and role = 'adult') then
      return false;
    end if;
  end loop;
  v_drop := nullif(c ->> 'drop_leave', '')::timestamptz;
  v_pick := nullif(c ->> 'pick_leave', '')::timestamptz;
  if v_drop is not null and (v_drop > t.event_start or v_drop < t.event_start - interval '4 hours') then return false; end if;
  if v_pick is not null and (v_pick < t.event_start or v_pick > coalesce(nullif(c ->> 'pick_at', '')::timestamptz, t.event_end) + interval '4 hours') then
    return false;
  end if;
  return true;
end;
$$;

-- ---------- bot ----------

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
    -- US-8: a choice may set each leg's own adult, leave time and note (a chained trip: one adult
    -- drops both children one after the other). Checked here: adults of this family, times near
    -- the activity (drop-off: up to 4 h before the start; pick-up: from the start to 4 h after the end).
    if not app_prj02.legs_ok(c, t, r.family_id) then return jsonb_build_object('ok', false, 'reason', 'bad_choice'); end if;
    update app_prj02.trips set status = 'assigned', owner_mode = c ->> 'mode',
           owner_person_id = case when c ->> 'mode' = 'adult' then v_who end,
           assigned_by = r.person_id, assigned_at = now(), updated_at = now(),
           -- A tap is the standard plan unless the choice says otherwise (Hub row 283).
           drop_mode = null, pick_mode = null, pick_at = null,
           drop_person = nullif(c ->> 'drop_person', '')::uuid, pick_person = nullif(c ->> 'pick_person', '')::uuid,
           drop_leave_set = nullif(c ->> 'drop_leave', '')::timestamptz, pick_leave_set = nullif(c ->> 'pick_leave', '')::timestamptz,
           drop_leave_at = coalesce(nullif(c ->> 'drop_leave', '')::timestamptz, drop_leave_at),
           pick_leave_at = coalesce(nullif(c ->> 'pick_leave', '')::timestamptz, pick_leave_at),
           drop_send_at = coalesce(nullif(c ->> 'drop_send', '')::timestamptz, drop_send_at),
           pick_send_at = coalesce(nullif(c ->> 'pick_send', '')::timestamptz, pick_send_at),
           drop_note = left(nullif(c ->> 'drop_note', ''), 120), pick_note = left(nullif(c ->> 'pick_note', ''), 120)
     where id = t.id
    returning * into t;
    delete from app_prj02.reminders where trip_id = t.id and kind in ('drop', 'pick') and status = 'due';
    insert into app_prj02.reminders (family_id, trip_id, person_id, kind, send_at)
      select r.family_id, t.id, l.who, l.kind, l.send_at
        from (values ('drop', t.drop_send_at, t.drop_needed, coalesce(t.drop_person, v_who)),
                     ('pick', t.pick_send_at, t.pick_needed, coalesce(t.pick_person, v_who))) as l (kind, send_at, needed, who)
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

create or replace function app_prj02.plan_decide(p_plan uuid, p_yes boolean) returns jsonb
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
    if not app_prj02.legs_ok(c, t, r.family_id) then raise exception 'plan has a bad leg' using errcode = '22023'; end if;
    update app_prj02.trips set status = 'assigned', owner_mode = c ->> 'mode',
           owner_person_id = case when c ->> 'mode' = 'adult' then v_who end,
           drop_mode = case when c ->> 'drop' in ('none', 'taxi', 'public') then c ->> 'drop' end,
           pick_mode = case when c ->> 'pick' in ('none', 'taxi', 'public') then c ->> 'pick' end,
           drop_person = nullif(c ->> 'drop_person', '')::uuid, pick_person = nullif(c ->> 'pick_person', '')::uuid,
           drop_leave_set = nullif(c ->> 'drop_leave', '')::timestamptz, pick_leave_set = nullif(c ->> 'pick_leave', '')::timestamptz,
           drop_leave_at = coalesce(nullif(c ->> 'drop_leave', '')::timestamptz, drop_leave_at),
           drop_send_at = coalesce(nullif(c ->> 'drop_send', '')::timestamptz, drop_send_at),
           drop_note = left(nullif(c ->> 'drop_note', ''), 120), pick_note = left(nullif(c ->> 'pick_note', ''), 120),
           pick_at = nullif(c ->> 'pick_at', '')::timestamptz,
           pick_leave_at = coalesce(nullif(c ->> 'pick_leave', '')::timestamptz, pick_leave_at),
           pick_send_at = coalesce(nullif(c ->> 'pick_send', '')::timestamptz, pick_send_at),
           assigned_by = r.person_id, assigned_at = now(), updated_at = now()
     where id = t.id
    returning * into t;
    delete from app_prj02.reminders where trip_id = t.id and kind in ('drop', 'pick') and status = 'due';
    insert into app_prj02.reminders (family_id, trip_id, person_id, kind, send_at)
      select r.family_id, t.id, l.who, l.kind, l.send_at
        from (values ('drop', t.drop_send_at, t.drop_needed and t.drop_mode is distinct from 'none', coalesce(t.drop_person, v_who)),
                     ('pick', t.pick_send_at, t.pick_needed and t.pick_mode is distinct from 'none', coalesce(t.pick_person, v_who))) as l (kind, send_at, needed, who)
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

create or replace function app_prj02.plan_pending() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r record; p record;
begin
  select * into r from app_prj02.request_adult();
  select tp.id, tp.status, tp.proposal, m.payload -> 'trips' as trips, m.payload -> 'between_min' as between_min into p
    from app_prj02.trip_plans tp join app_prj02.reminders m on m.id = tp.clash_id
   where tp.person_id = r.person_id and tp.status in ('awaiting', 'proposed') and tp.expires_at > now()
   order by tp.created_at desc limit 1;
  if p.id is null then return null; end if;
  return jsonb_build_object('plan', p.id, 'status', p.status, 'proposal', p.proposal, 'trips', p.trips, 'between_min', p.between_min);
end;
$$;

-- ---------- forget ----------
-- Replaced to unlink the person from drop_person and pick_person.
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
                             assigned_by     = case when assigned_by = p_person then null else assigned_by end,
                             drop_person     = case when drop_person = p_person then null else drop_person end,
                             pick_person     = case when pick_person = p_person then null else pick_person end
   where owner_person_id = p_person or assigned_by = p_person or drop_person = p_person or pick_person = p_person;
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
revoke execute on all functions in schema app_prj02 from public, anon, authenticated;
revoke execute on function app_prj02.legs_ok(jsonb, app_prj02.trips, uuid) from app_prj02_bot, app_prj02_job;
grant execute on function app_prj02.assign_trips(jsonb), app_prj02.plan_decide(uuid, boolean), app_prj02.plan_pending() to app_prj02_bot;
-- forget(): owner only.
