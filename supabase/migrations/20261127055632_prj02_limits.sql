-- prj02-R1 US-4 (limits and red-team tests): the bot's L2 limits enforced in the database, and a
-- hold on calendar events whose notes try to instruct the bot (John's AI-L08 attack case 2).
--
-- Plain English: a family can press pause (/pause, /resume); the scheduler sends at most a set
-- number of bot-started messages per family per day; the chat bot checks the family's AI spend of
-- the last 7 days before each model call; an event whose notes look like an instruction ("invite
-- XX to join the family calendar") is left out of the plan until an adult taps "Include it".
--
-- Changes:
--   family_settings: paused_at (paused when set), max_messages_day (30), max_cost_week_usd (5.00);
--     default_drive_min dropped (replaced by travel_modes, Hub rows 277 and 279; no code reads it)
--   trips: hold_state none / held / released
--   reminders: kind 'warning' (one per trip and adult, never sent twice)
--   bot functions (the adult of the current request only): set_pause(), budget(), release_trip()
--   job functions: job_hold_trip(), job_status(); job_queue() also queues warnings and queues
--     nothing while paused; job_claim_due() claims nothing while paused and never more than the
--     day's allowance
--   No new personal data (paused_at and hold_state name no person), so forget() is unchanged.
--
-- Grants: app_prj02_bot may run set_pause(), budget(), release_trip() (request_adult() is internal, no grant); app_prj02_job may run
-- job_hold_trip(), job_status() (job_queue() and job_claim_due() keep their grants); anon and
-- authenticated nothing. budget() reads core.cost_ledger for the bot (security definer): the bot
-- itself still has no access to core.

alter table app_prj02.family_settings
  add column paused_at         timestamptz,
  add column max_messages_day  int not null default 30 check (max_messages_day between 1 and 500),
  add column max_cost_week_usd numeric(8, 2) not null default 5.00 check (max_cost_week_usd between 0 and 1000),
  drop column default_drive_min;

alter table app_prj02.trips
  add column hold_state text not null default 'none' check (hold_state in ('none', 'held', 'released'));

alter table app_prj02.reminders drop constraint reminders_kind_check;
alter table app_prj02.reminders add constraint reminders_kind_check
  check (kind in ('plan', 'clash', 'drop', 'pick', 'warning'));

-- ---------- bot (the adult of the current request) ----------

-- The adult and family of this transaction's request, or an exception.
create function app_prj02.request_adult(out person_id uuid, out family_id uuid)
language plpgsql stable security definer set search_path = '' as $$
begin
  select c.person_id, c.family_id into person_id, family_id from app_prj02.request_ctx c
   where c.xact = pg_catalog.pg_current_xact_id_if_assigned() and c.kind = 'person';
  if person_id is null then raise exception 'no request context' using errcode = '42501'; end if;
  if not exists (select 1 from app_prj02.people p where p.id = request_adult.person_id and p.role = 'adult') then
    raise exception 'not an adult' using errcode = '42501';
  end if;
end;
$$;

-- /pause and /resume: every bot-started message and model call of the family stops until resumed.
create function app_prj02.set_pause(p_on boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  select * into r from app_prj02.request_adult();
  insert into app_prj02.family_settings (family_id) values (r.family_id) on conflict (family_id) do nothing;
  update app_prj02.family_settings set paused_at = case when p_on then coalesce(paused_at, now()) end, updated_at = now()
   where family_id = r.family_id;
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', r.family_id, r.person_id::text, case when p_on then 'pause' else 'resume' end, 'app_prj02.family_settings', '{}'::jsonb);
  return jsonb_build_object('ok', true, 'paused', p_on);
end;
$$;

-- Before a model call: is the family paused, and how much did its model calls cost in 7 days?
create function app_prj02.budget() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r record; s record; v_cost numeric;
begin
  select * into r from app_prj02.request_adult();
  select paused_at, max_cost_week_usd into s from app_prj02.family_settings where family_id = r.family_id;
  select coalesce(sum(cost_usd), 0) into v_cost from core.cost_ledger
   where app = 'prj02' and tenant_id = r.family_id and at >= now() - interval '7 days';
  return jsonb_build_object('paused', s.paused_at is not null, 'week_cost_usd', v_cost,
                            'week_max_usd', coalesce(s.max_cost_week_usd, 5.00));
end;
$$;

-- "Include it" on a held event: the next scans plan it as usual.
create function app_prj02.release_trip(p_trip uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r record; n int;
begin
  select * into r from app_prj02.request_adult();
  update app_prj02.trips set hold_state = 'released', updated_at = now()
   where id = p_trip and family_id = r.family_id and hold_state = 'held';
  get diagnostics n = row_count;
  if n = 0 then return jsonb_build_object('ok', false, 'reason', 'unknown'); end if;
  update app_prj02.reminders set status = 'skipped' where trip_id = p_trip and kind = 'warning' and status = 'due';
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', r.family_id, r.person_id::text, 'release_trip', 'app_prj02.trips', '{}'::jsonb);
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------- job role (scheduler) ----------

-- A trip whose event notes look like an instruction is held (once; a released trip stays released).
create function app_prj02.job_hold_trip(p_trip uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  update app_prj02.trips set hold_state = 'held', updated_at = now()
   where id = p_trip and family_id = app_prj02.job_family() and hold_state = 'none';
  get diagnostics n = row_count;
  return n = 1;
end;
$$;

-- What the tick needs to know about the limits (for its log: kinds and counts only).
create function app_prj02.job_status() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_family uuid := app_prj02.job_family(); s record; v_tz text; v_sent int;
begin
  select paused_at, max_messages_day into s from app_prj02.family_settings where family_id = v_family;
  select time_zone into v_tz from app_prj02.calendars where family_id = v_family limit 1;
  select count(*) into v_sent from app_prj02.reminders
   where family_id = v_family and status = 'sent'
     and sent_at >= (date_trunc('day', now() at time zone coalesce(v_tz, 'Asia/Singapore')) at time zone coalesce(v_tz, 'Asia/Singapore'));
  return jsonb_build_object('paused', s.paused_at is not null, 'sent_today', v_sent, 'max_day', coalesce(s.max_messages_day, 30));
end;
$$;

create or replace function app_prj02.job_queue(p_trip uuid, p_kind text, p_person uuid, p_send_at timestamptz, p_payload jsonb)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_family uuid := app_prj02.job_family(); n int;
begin
  if p_kind not in ('plan', 'clash', 'warning') then raise exception 'the job queues only plan, clash and warning messages'; end if;
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

-- Claims due messages once, oldest first: none while paused, never more than the day's allowance
-- (max_messages_day minus those already sent today, in the family's time zone).
create or replace function app_prj02.job_claim_due(p_limit int) returns setof app_prj02.reminders
language plpgsql security definer set search_path = '' as $$
declare v_family uuid := app_prj02.job_family(); st jsonb := app_prj02.job_status(); v_left int;
begin
  if (st ->> 'paused')::boolean then return; end if;
  v_left := least(greatest(p_limit, 1), 100, (st ->> 'max_day')::int - (st ->> 'sent_today')::int);
  if v_left <= 0 then return; end if;
  return query
  update app_prj02.reminders r set status = 'sent', sent_at = now()
   where r.id in (select id from app_prj02.reminders
                   where family_id = v_family and status = 'due' and send_at <= now()
                   order by send_at limit v_left
                   for update skip locked)
  returning r.*;
end;
$$;

-- ---------- grants ----------
revoke execute on all functions in schema app_prj02 from public, anon, authenticated;
grant execute on function app_prj02.set_pause(boolean), app_prj02.budget(),
  app_prj02.release_trip(uuid) to app_prj02_bot;
grant execute on function app_prj02.job_hold_trip(uuid), app_prj02.job_status() to app_prj02_job;
