-- prj02-R1 US-9 (choices for every trip, learned from past choices), decision 27/11/2026 Hub row
-- 308, from gap Hub row 307 (a single trip's message had no 'My own plan…' and no 'wait there'
-- choice; a tapped choice could be tapped again).
--
-- Plain English: every message with buttons offers the ways the family usually does a trip.
-- The ways themselves (drop off and wait, car there and taxi back, walk, ...) are a list in the
-- bot's settings, combined with the family's adults when a message is made, so nothing here
-- stores the combinations. This migration only lets each trip say exactly how it was done, so
-- the next trip of the same activity can offer the same way first, and stops a second tap.
--
-- Changes:
--   trips: wait_there (the adult waits at the place between drop-off and pick-up); a leg can also
--     be 'walk'
--   legs_ok(): a wait needs one adult for both legs
--   assign_trips(): checks every choice before changing anything; takes each leg's way
--     (drop_mode, pick_mode: none, taxi, public, walk) and the wait; a choice from a message
--     ('message') is refused with 'already' when its trip was decided after the message was sent
--     (a second tap, or another adult's tap on their copy)
--   plan_decide(): legs may also be 'walk'; takes the wait
--   clash_options(): also the options of a 'who takes it?' message, with when it was sent
--   plan_await(): "My own plan…" under a 'who takes it?' message too
--
-- Grants: unchanged (the bot keeps assign_trips, plan_decide, clash_options, plan_await;
-- legs_ok is internal); anon and authenticated nothing. No new table, no personal data.

alter table app_prj02.trips add column wait_there boolean not null default false;
alter table app_prj02.trips drop constraint trips_drop_mode_check;
alter table app_prj02.trips drop constraint trips_pick_mode_check;
alter table app_prj02.trips add constraint trips_drop_mode_check check (drop_mode is null or drop_mode in ('none', 'taxi', 'public', 'walk'));
alter table app_prj02.trips add constraint trips_pick_mode_check check (pick_mode is null or pick_mode in ('none', 'taxi', 'public', 'walk'));

-- A choice's legs: each named adult is an adult of this family; a drop-off leave time is at most 4 h
-- before the start (and not after it); a pick-up leave time is between the start and 4 h after the
-- end; a wait there needs the same adult for both legs.
create or replace function app_prj02.legs_ok(c jsonb, t app_prj02.trips, p_family uuid) returns boolean
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
  if coalesce((c ->> 'wait')::boolean, false)
     and coalesce(nullif(c ->> 'drop_person', ''), c ->> 'person') is distinct from coalesce(nullif(c ->> 'pick_person', ''), c ->> 'person') then
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
  v_sent timestamptz;
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
  -- US-9: every choice is checked (and its trip locked) before anything changes.
  for c in select * from jsonb_array_elements(p_choices) loop
    select * into t from app_prj02.trips
     where id = (c ->> 'trip')::uuid and family_id = r.family_id for update;
    if not found or t.status = 'cancelled' then return jsonb_build_object('ok', false, 'reason', 'unknown'); end if;
    if c ->> 'mode' = 'adult' then
      if not exists (select 1 from app_prj02.people where id = (c ->> 'person')::uuid and family_id = r.family_id and role = 'adult') then
        return jsonb_build_object('ok', false, 'reason', 'bad_choice');
      end if;
    elsif c ->> 'mode' not in ('taxi', 'public') or c ->> 'mode' is null then
      return jsonb_build_object('ok', false, 'reason', 'bad_choice');
    end if;
    if coalesce(c ->> 'drop_mode', 'none') not in ('none', 'taxi', 'public', 'walk')
       or coalesce(c ->> 'pick_mode', 'none') not in ('none', 'taxi', 'public', 'walk') then
      return jsonb_build_object('ok', false, 'reason', 'bad_choice');
    end if;
    -- US-8: each leg's own adult, leave time and note; checked here (adults of this family, times
    -- near the activity, one adult for a wait there).
    if not app_prj02.legs_ok(c, t, r.family_id) then return jsonb_build_object('ok', false, 'reason', 'bad_choice'); end if;
    -- US-9: a choice from a message is taken once: decided after the message was sent = already.
    if c ? 'message' then
      select sent_at into v_sent from app_prj02.reminders
       where id = (c ->> 'message')::uuid and family_id = r.family_id and kind in ('plan', 'clash');
      if not found then return jsonb_build_object('ok', false, 'reason', 'unknown'); end if;
      if t.status = 'assigned' and v_sent is not null and t.assigned_at >= v_sent then
        return jsonb_build_object('ok', false, 'reason', 'already', 'by', t.assigned_by, 'at', t.assigned_at);
      end if;
    end if;
  end loop;
  for c in select * from jsonb_array_elements(p_choices) loop
    select * into t from app_prj02.trips where id = (c ->> 'trip')::uuid and family_id = r.family_id;
    v_who := case when c ->> 'mode' = 'adult' then (c ->> 'person')::uuid else r.person_id end;
    update app_prj02.trips set status = 'assigned', owner_mode = c ->> 'mode',
           owner_person_id = case when c ->> 'mode' = 'adult' then v_who end,
           assigned_by = r.person_id, assigned_at = now(), updated_at = now(),
           -- A tap is the standard plan unless the choice says otherwise (Hub row 283); each leg's
           -- way (US-9) and the wait come from the choice.
           drop_mode = nullif(c ->> 'drop_mode', ''), pick_mode = nullif(c ->> 'pick_mode', ''), pick_at = null,
           wait_there = coalesce((c ->> 'wait')::boolean, false),
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
        from (values ('drop', t.drop_send_at, t.drop_needed and t.drop_mode is distinct from 'none', coalesce(t.drop_person, v_who)),
                     ('pick', t.pick_send_at, t.pick_needed and t.pick_mode is distinct from 'none', coalesce(t.pick_person, v_who))) as l (kind, send_at, needed, who)
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
           drop_mode = case when c ->> 'drop' in ('none', 'taxi', 'public', 'walk') then c ->> 'drop' end,
           pick_mode = case when c ->> 'pick' in ('none', 'taxi', 'public', 'walk') then c ->> 'pick' end,
           wait_there = coalesce((c ->> 'wait')::boolean, false),
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

-- What a clash or 'who takes it?' message offered (stored with the message, not in the button),
-- with when it was sent.
create or replace function app_prj02.clash_options(p_reminder uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select r.payload || jsonb_build_object('kind', r.kind, 'sent_at', r.sent_at) from app_prj02.reminders r
    join app_prj02.request_ctx c on c.family_id = r.family_id
   where r.id = p_reminder and r.kind in ('clash', 'plan')
     and c.xact = pg_catalog.pg_current_xact_id_if_assigned() and c.kind = 'person';
$$;

-- "My own plan…" tapped under a clash or 'who takes it?' message: the adult's next words are read
-- as their plan.
create or replace function app_prj02.plan_await(p_clash uuid, p_minutes int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r record; v_id uuid;
begin
  select * into r from app_prj02.request_adult();
  if not exists (select 1 from app_prj02.reminders where id = p_clash and family_id = r.family_id and kind in ('clash', 'plan')) then
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

-- ---------- grants ----------
revoke execute on all functions in schema app_prj02 from public, anon, authenticated;
revoke execute on function app_prj02.legs_ok(jsonb, app_prj02.trips, uuid) from app_prj02_bot, app_prj02_job;
grant execute on function app_prj02.assign_trips(jsonb), app_prj02.plan_decide(uuid, boolean),
  app_prj02.clash_options(uuid), app_prj02.plan_await(uuid, int) to app_prj02_bot;
