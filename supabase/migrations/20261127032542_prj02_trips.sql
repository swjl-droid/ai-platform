-- ai-platform: trips, reminders and the scheduler of prj02 (Family orchestrator), story prj02-R1
-- US-3 (reminders and clashes).
-- Applied 27/11/2026 after John's "yes, apply"; file named from the recorded version (CLAUDE.md rule 3).
--
-- Decisions (27/11/2026): US-3 release-1 slice, option B (evening 'who takes it?' taps, one-car
-- clash options computed in code, reminders at leave time, quiet hours, OneMap or an estimate);
-- scheduled jobs use their own role app_prj02_job (amends Hub row 249: the chat bot role still
-- never names a family); ADR-02 scheduler: Supabase Cron calls /api/tick every minute.
--
-- Two doors into app_prj02:
--   app_prj02_bot  a family member's message: begin_request(channel, account), as before
--   app_prj02_job  a scheduled job: begin_job(family); only /api/tick uses this role
-- Both write request_ctx (kind person / job); is_member() reads it the same way.
--
-- Who may do what:
--   anon, authenticated  nothing
--   app_prj02_bot        read its family's trips; assign trips (any adult's tap is the yes)
--   app_prj02_job        list families with a calendar; open a job for one; read that family;
--                        write its trips, reminders and saved places; claim due reminders
--   owner (postgres)     set_family_settings(), set_driver()
-- forget(): replaced below to clear the new tables too.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'app_prj02_job') then
    -- No password here: John sets it in the Supabase SQL editor, so no secret is in git.
    create role app_prj02_job login noinherit nobypassrls connection limit 5;
  end if;
end $$;
alter role app_prj02_job set statement_timeout = '10s';

-- request_ctx: a job has a family but no person.
alter table app_prj02.request_ctx add column kind text not null default 'person' check (kind in ('person', 'job'));
alter table app_prj02.request_ctx alter column person_id drop not null;
alter table app_prj02.request_ctx add constraint request_ctx_person_or_job check (kind = 'job' or person_id is not null);

-- begin_request() replaced only to mark its context as a person's (first version in
-- 20261127005951_prj02_tenancy.sql; behaviour otherwise unchanged).
create or replace function app_prj02.begin_request(p_channel text, p_account text) returns jsonb
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
  insert into app_prj02.request_ctx (xact, family_id, person_id, kind) values (v_xact, r.family_id, r.person_id, 'person')
    on conflict (xact) do update set family_id = excluded.family_id, person_id = excluded.person_id, kind = 'person', at = now();
  return jsonb_build_object(
    'person_id', r.person_id, 'family_id', r.family_id, 'display_name', r.display_name,
    'role', r.role, 'is_admin', r.is_admin,
    'notice_version', (select c.notice_version from app_prj02.consents c
                        where c.person_id = r.person_id order by c.agreed_at desc limit 1));
end;
$$;

-- Who drives (family setting per adult).
alter table app_prj02.people add column can_drive boolean not null default false;

-- Family settings (Hub row 128: every number a setting).
create table app_prj02.family_settings (
  family_id          uuid primary key references app_prj02.families (id) on delete cascade,
  home_postal        text check (home_postal is null or home_postal ~ '^[0-9]{6}$'),
  home_lat           double precision,
  home_lng           double precision,
  cars               int  not null default 1 check (cars between 0 and 9),
  plan_time          time not null default '19:00',
  quiet_start        time not null default '22:00',
  quiet_end          time not null default '07:00',
  evening_slot       time not null default '21:30',
  drop_buffer_min    int  not null default 10 check (drop_buffer_min between 0 and 120),
  pick_buffer_min    int  not null default 5  check (pick_buffer_min between 0 and 120),
  default_drive_min  int  not null default 20 check (default_drive_min between 1 and 240),
  scan_minutes       int  not null default 15 check (scan_minutes between 1 and 1440),
  last_scan_at       timestamptz,
  updated_at         timestamptz not null default now()
);

-- Saved places: drive time from home, learned once per location text (Hub row 134).
create table app_prj02.places (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references app_prj02.families (id) on delete cascade,
  label_key   text not null check (length(label_key) between 1 and 200),
  lat         double precision,
  lng         double precision,
  drive_min   int  not null check (drive_min between 0 and 600),
  source      text not null check (source in ('onemap', 'estimate', 'parent')),
  updated_at  timestamptz not null default now(),
  unique (family_id, label_key)
);

-- One trip per activity (release 1: one owner takes and fetches).
create table app_prj02.trips (
  id               uuid primary key default gen_random_uuid(),
  family_id        uuid not null references app_prj02.families (id) on delete cascade,
  event_id         text not null check (length(event_id) between 1 and 1024),
  event_start      timestamptz not null,
  event_end        timestamptz not null,
  title            text not null check (length(title) between 1 and 200),
  location         text check (location is null or length(location) <= 300),
  drive_min        int  not null check (drive_min between 0 and 600),
  drive_source     text not null check (drive_source in ('onemap', 'estimate', 'parent')),
  drop_leave_at    timestamptz not null,
  pick_leave_at    timestamptz not null,
  drop_send_at     timestamptz not null,
  pick_send_at     timestamptz not null,
  status           text not null default 'open' check (status in ('open', 'assigned', 'cancelled')),
  owner_person_id  uuid,
  owner_mode       text check (owner_mode is null or owner_mode in ('adult', 'taxi', 'public')),
  assigned_by      uuid,
  assigned_at      timestamptz,
  updated_at       timestamptz not null default now(),
  unique (family_id, event_id, event_start),
  unique (id, family_id),
  check (event_end >= event_start),
  foreign key (owner_person_id, family_id) references app_prj02.people (id, family_id) on delete set null (owner_person_id),
  foreign key (assigned_by, family_id) references app_prj02.people (id, family_id) on delete set null (assigned_by)
);
create index trips_family_start on app_prj02.trips (family_id, event_start);
comment on table app_prj02.trips is 'one trip per family activity: drive time, leave times (quiet hours applied in drop_send_at / pick_send_at), who takes it after an adult''s tap';

-- Outbox of bot-started messages: evening 'who takes it?' (plan), clash options, reminders.
-- One row per (trip, kind, person): a message is never sent twice.
create table app_prj02.reminders (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references app_prj02.families (id) on delete cascade,
  trip_id     uuid not null,
  person_id   uuid not null,
  kind        text not null check (kind in ('plan', 'clash', 'drop', 'pick')),
  send_at     timestamptz not null,
  status      text not null default 'due' check (status in ('due', 'sent', 'skipped', 'failed')),
  payload     jsonb not null default '{}'::jsonb,
  sent_at     timestamptz,
  created_at  timestamptz not null default now(),
  unique (trip_id, kind, person_id),
  foreign key (trip_id, family_id) references app_prj02.trips (id, family_id) on delete cascade,
  foreign key (person_id, family_id) references app_prj02.people (id, family_id) on delete cascade
);
create index reminders_due on app_prj02.reminders (family_id, status, send_at);

alter table app_prj02.family_settings enable row level security;
alter table app_prj02.places          enable row level security;
alter table app_prj02.trips           enable row level security;
alter table app_prj02.reminders       enable row level security;

-- One policy per line. The chat bot reads its family's settings and trips; the job role reads what
-- its job needs (the family it opened), through the same is_member().
create policy family_settings_read on app_prj02.family_settings for select to app_prj02_bot using (app_prj02.is_member(family_id));
create policy trips_read on app_prj02.trips for select to app_prj02_bot using (app_prj02.is_member(family_id));
create policy places_none on app_prj02.places for select to app_prj02_bot using (false);
create policy reminders_none on app_prj02.reminders for select to app_prj02_bot using (false);
create policy job_families_read on app_prj02.families for select to app_prj02_job using (app_prj02.is_member(id));
create policy job_people_read on app_prj02.people for select to app_prj02_job using (app_prj02.is_member(family_id));
create policy job_contacts_read on app_prj02.contacts for select to app_prj02_job using (app_prj02.is_member(family_id));
create policy job_calendars_read on app_prj02.calendars for select to app_prj02_job using (app_prj02.is_member(family_id));
create policy job_family_settings_read on app_prj02.family_settings for select to app_prj02_job using (app_prj02.is_member(family_id));
create policy job_places_read on app_prj02.places for select to app_prj02_job using (app_prj02.is_member(family_id));
create policy job_trips_read on app_prj02.trips for select to app_prj02_job using (app_prj02.is_member(family_id));
create policy job_reminders_read on app_prj02.reminders for select to app_prj02_job using (app_prj02.is_member(family_id));

-- ---------- owner ----------

create function app_prj02.set_family_settings(p_family uuid, p_home_postal text, p_cars int) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into app_prj02.family_settings (family_id, home_postal, cars)
    values (p_family, nullif(btrim(p_home_postal), ''), p_cars)
  on conflict (family_id) do update set home_postal = excluded.home_postal, cars = excluded.cars,
    home_lat = case when app_prj02.family_settings.home_postal is distinct from excluded.home_postal then null else app_prj02.family_settings.home_lat end,
    home_lng = case when app_prj02.family_settings.home_postal is distinct from excluded.home_postal then null else app_prj02.family_settings.home_lng end,
    updated_at = now();
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', p_family, 'system', 'set_family_settings', 'app_prj02.family_settings', jsonb_build_object('cars', p_cars));
end;
$$;

create function app_prj02.set_driver(p_person uuid, p_can_drive boolean) returns void
language sql security definer set search_path = '' as $$
  update app_prj02.people set can_drive = p_can_drive where id = p_person and role = 'adult';
$$;

-- ---------- job role (scheduler) ----------

-- Families the scheduler works for (those with a calendar).
create function app_prj02.job_families() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select c.family_id from app_prj02.calendars c order by c.family_id;
$$;

-- Opens a job for one family in the current transaction (no person).
create function app_prj02.begin_job(p_family uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_xact xid8 := pg_catalog.pg_current_xact_id();
begin
  delete from app_prj02.request_ctx where at < now() - interval '15 minutes';
  if not exists (select 1 from app_prj02.families where id = p_family) then
    delete from app_prj02.request_ctx where xact = v_xact;
    return false;
  end if;
  insert into app_prj02.family_settings (family_id) values (p_family) on conflict (family_id) do nothing;
  insert into app_prj02.request_ctx (xact, family_id, person_id, kind) values (v_xact, p_family, null, 'job')
    on conflict (xact) do update set family_id = excluded.family_id, person_id = null, kind = 'job', at = now();
  return true;
end;
$$;

-- The family of the current job; raises outside a job.
create function app_prj02.job_family() returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare v uuid;
begin
  select family_id into v from app_prj02.request_ctx
   where xact = pg_catalog.pg_current_xact_id_if_assigned() and kind = 'job';
  if v is null then raise exception 'no job context' using errcode = '42501'; end if;
  return v;
end;
$$;

create function app_prj02.job_mark_scan(p_home_lat double precision, p_home_lng double precision) returns void
language sql security definer set search_path = '' as $$
  update app_prj02.family_settings set last_scan_at = now(),
         home_lat = coalesce(p_home_lat, home_lat), home_lng = coalesce(p_home_lng, home_lng)
   where family_id = app_prj02.job_family();
$$;

create function app_prj02.job_save_place(p_label_key text, p_lat double precision, p_lng double precision,
                                         p_drive_min int, p_source text) returns void
language sql security definer set search_path = '' as $$
  insert into app_prj02.places (family_id, label_key, lat, lng, drive_min, source)
    values (app_prj02.job_family(), lower(btrim(p_label_key)), p_lat, p_lng, p_drive_min, p_source)
  on conflict (family_id, label_key) do update set lat = excluded.lat, lng = excluded.lng,
    drive_min = excluded.drive_min, source = excluded.source, updated_at = now();
$$;

-- Records a trip found in the calendar (or updates its times). A trip already assigned keeps its
-- owner; its unsent reminders follow the new times. Returns the trip id.
create function app_prj02.job_upsert_trip(p_event_id text, p_start timestamptz, p_end timestamptz, p_title text,
  p_location text, p_drive_min int, p_drive_source text, p_drop_leave timestamptz, p_pick_leave timestamptz,
  p_drop_send timestamptz, p_pick_send timestamptz) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_family uuid := app_prj02.job_family(); v_id uuid;
begin
  insert into app_prj02.trips (family_id, event_id, event_start, event_end, title, location, drive_min, drive_source,
                               drop_leave_at, pick_leave_at, drop_send_at, pick_send_at)
    values (v_family, p_event_id, p_start, p_end, left(btrim(p_title), 200), left(btrim(p_location), 300), p_drive_min,
            p_drive_source, p_drop_leave, p_pick_leave, p_drop_send, p_pick_send)
  on conflict (family_id, event_id, event_start) do update set
    event_end = excluded.event_end, title = excluded.title, location = excluded.location,
    drive_min = excluded.drive_min, drive_source = excluded.drive_source,
    drop_leave_at = excluded.drop_leave_at, pick_leave_at = excluded.pick_leave_at,
    drop_send_at = excluded.drop_send_at, pick_send_at = excluded.pick_send_at,
    status = case when app_prj02.trips.status = 'cancelled' then 'open' else app_prj02.trips.status end,
    updated_at = now()
  returning id into v_id;
  update app_prj02.reminders r set send_at = case r.kind when 'drop' then p_drop_send else p_pick_send end
   where r.trip_id = v_id and r.status = 'due' and r.kind in ('drop', 'pick');
  return v_id;
end;
$$;

-- Trips in the window whose event is no longer in the calendar are cancelled; their unsent
-- messages are skipped.
create function app_prj02.job_cancel_missing(p_from timestamptz, p_to timestamptz, p_keep uuid[]) returns int
language plpgsql security definer set search_path = '' as $$
declare v_family uuid := app_prj02.job_family(); n int;
begin
  update app_prj02.trips set status = 'cancelled', updated_at = now()
   where family_id = v_family and event_start >= p_from and event_start < p_to
     and status <> 'cancelled' and not (id = any (coalesce(p_keep, '{}')));
  get diagnostics n = row_count;
  update app_prj02.reminders r set status = 'skipped'
    from app_prj02.trips t
   where r.trip_id = t.id and t.family_id = v_family and t.status = 'cancelled' and r.status = 'due';
  return n;
end;
$$;

-- Queues a message once (no-op if that trip, kind and person already have one).
create function app_prj02.job_queue(p_trip uuid, p_kind text, p_person uuid, p_send_at timestamptz, p_payload jsonb)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_family uuid := app_prj02.job_family(); n int;
begin
  if p_kind not in ('plan', 'clash') then raise exception 'the job queues only plan and clash messages'; end if;
  insert into app_prj02.reminders (family_id, trip_id, person_id, kind, send_at, payload)
    values (v_family, p_trip, p_person, p_kind, p_send_at, coalesce(p_payload, '{}'::jsonb))
  on conflict (trip_id, kind, person_id) do nothing;
  get diagnostics n = row_count;
  return n = 1;
end;
$$;

-- Claims the family's due messages: each is marked sent before it goes out (at most once).
create function app_prj02.job_claim_due(p_limit int) returns setof app_prj02.reminders
language sql security definer set search_path = '' as $$
  update app_prj02.reminders r set status = 'sent', sent_at = now()
   where r.id in (select id from app_prj02.reminders
                   where family_id = app_prj02.job_family() and status = 'due' and send_at <= now()
                   order by send_at limit least(greatest(p_limit, 1), 100)
                   for update skip locked)
  returning r.*;
$$;

create function app_prj02.job_mark_failed(p_reminder uuid) returns void
language sql security definer set search_path = '' as $$
  update app_prj02.reminders set status = 'failed' where id = p_reminder and family_id = app_prj02.job_family();
$$;

-- ---------- chat bot role (an adult's tap) ----------

-- Assigns one or more trips of the adult's family (one tap = the yes). p_choices is a list of
-- {"trip": uuid, "mode": "adult" | "taxi" | "public", "person": uuid (for adult)}. Reminders go to
-- the owner; for taxi or public transport, to the adult who tapped. Reassigning replaces the
-- trip's unsent reminders.
create function app_prj02.assign_trips(p_choices jsonb) returns jsonb
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
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', r.family_id, r.person_id::text, 'assign_trips', 'app_prj02.trips', jsonb_build_object('trips', n));
  return jsonb_build_object('ok', true, 'assigned', n);
end;
$$;

-- What a clash message offered (the options are stored with the message, not in the button).
create function app_prj02.clash_options(p_reminder uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select r.payload from app_prj02.reminders r
    join app_prj02.request_ctx c on c.family_id = r.family_id
   where r.id = p_reminder and r.kind = 'clash'
     and c.xact = pg_catalog.pg_current_xact_id_if_assigned() and c.kind = 'person';
$$;

-- ---------- forget ----------

-- Forget me, replaced to cover the new tables (first version in 20261127005951_prj02_tenancy.sql,
-- replaced in 20261127021550_prj02_calendar.sql). Added:
--   app_prj02.trips: owner and assigned_by unlinked when the family stays; deleted with it otherwise
--   app_prj02.reminders: the person's messages deleted; all deleted with the family
--   app_prj02.family_settings, app_prj02.places: deleted with the family
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
    'app_prj02.families', n_families,
    'core.audit_log', n_audit, 'core.cost_ledger', n_cost, 'core.agent_runs', n_runs,
    'core.agent_runs_unlinked', n_waiting);
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj02', null, 'system', 'forget', null, v_counts);
  return v_counts;
end;
$$;

-- ---------- scheduler (ADR-02) ----------
-- Supabase Cron calls the tick once a minute. The tick takes no input and never sends a message
-- twice (reminders are claimed once), so its address needs no secret. Skipped where the
-- extensions are not available (the CI rehearsal database).
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron')
     and exists (select 1 from pg_available_extensions where name = 'pg_net') then
    execute 'create extension if not exists pg_net with schema extensions';
    execute 'create extension if not exists pg_cron with schema pg_catalog';
    execute $c$select cron.schedule('prj02-tick', '* * * * *', 'select net.http_get(''https://prj02.vercel.app/api/tick'')')$c$;
  end if;
end $$;

-- ---------- grants ----------
revoke all on app_prj02.family_settings, app_prj02.places, app_prj02.trips, app_prj02.reminders from public, anon, authenticated;
revoke execute on all functions in schema app_prj02 from public, anon, authenticated;

grant usage on schema app_prj02 to app_prj02_job;
grant select on app_prj02.families, app_prj02.people, app_prj02.contacts, app_prj02.calendars,
  app_prj02.family_settings, app_prj02.places, app_prj02.trips, app_prj02.reminders to app_prj02_job;
grant execute on function app_prj02.is_member(uuid), app_prj02.job_families(), app_prj02.begin_job(uuid),
  app_prj02.job_family(), app_prj02.job_mark_scan(double precision, double precision),
  app_prj02.job_save_place(text, double precision, double precision, int, text),
  app_prj02.job_upsert_trip(text, timestamptz, timestamptz, text, text, int, text, timestamptz, timestamptz, timestamptz, timestamptz),
  app_prj02.job_cancel_missing(timestamptz, timestamptz, uuid[]), app_prj02.job_queue(uuid, text, uuid, timestamptz, jsonb),
  app_prj02.job_claim_due(int), app_prj02.job_mark_failed(uuid)
  to app_prj02_job;

grant select on app_prj02.family_settings, app_prj02.trips, app_prj02.places, app_prj02.reminders to app_prj02_bot;
grant execute on function app_prj02.assign_trips(jsonb), app_prj02.clash_options(uuid) to app_prj02_bot;
-- set_family_settings(), set_driver() and forget(): owner only.
