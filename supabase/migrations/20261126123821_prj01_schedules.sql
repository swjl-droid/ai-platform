-- ai-platform: imported project schedules for prj01 (PM copilot), story prj01-R1 US-2 (schedule import).
-- Design decided by John 26/11/2026 (Hub row 239): one generic schema for every method, with the
-- method's labels and extra columns kept as data in prj01 (lib/schedule/profiles.json), not here.
-- Every item has the same 12 slots (key, name, type, parent, start, finish, duration, size, owner,
-- status, links, notes); method extras go into the jsonb column extras.
--
-- Separation rule (CLAUDE.md "Tenant separation"): every table carries org_id and has RLS through
-- app_prj01.is_member(). Composite foreign keys tie each row to its project's organisation, so a row
-- can never point at another organisation's project or schedule.
--
-- Who may do what:
--   anon           nothing
--   authenticated  read, add and delete schedules, items and links of their own organisations,
--                  through import_schedule() (one call = one schedule, all or nothing); no updates
--                  in release 1 (a corrected file is imported as a new schedule)
-- forget(): updated below to count the schedule rows it removes.

alter table app_prj01.projects add constraint projects_id_org_key unique (id, org_id);

create table app_prj01.schedules (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null,
  project_id   uuid not null,
  method       text not null check (length(method) between 1 and 40),
  source_name  text not null check (length(source_name) between 1 and 300),
  item_count   int  not null check (item_count >= 0),
  link_count   int  not null check (link_count >= 0),
  imported_by  uuid default auth.uid() references auth.users (id) on delete set null,
  imported_at  timestamptz not null default now(),
  unique (id, org_id),
  foreign key (project_id, org_id) references app_prj01.projects (id, org_id) on delete cascade
);
create index schedules_project on app_prj01.schedules (project_id);

create table app_prj01.schedule_items (
  schedule_id  uuid not null,
  org_id       uuid not null,
  position     int  not null check (position >= 0),
  key          text not null check (length(key) between 1 and 60),
  name         text not null check (length(name) between 1 and 300),
  type         text not null check (length(type) between 1 and 60),
  parent       text,
  start_date   date,
  finish_date  date,
  duration     text,
  size         numeric,
  owner        text,
  status       text,
  notes        text,
  extras       jsonb not null default '{}'::jsonb check (jsonb_typeof(extras) = 'object'),
  primary key (schedule_id, key),
  unique (schedule_id, position),
  check (finish_date is null or start_date is null or finish_date >= start_date),
  foreign key (schedule_id, org_id) references app_prj01.schedules (id, org_id) on delete cascade,
  foreign key (schedule_id, parent) references app_prj01.schedule_items (schedule_id, key)
    on delete cascade deferrable initially deferred
);

-- A link means: to_key depends on from_key (from_key is its predecessor), with a link type and a lag.
create table app_prj01.schedule_links (
  schedule_id  uuid not null,
  org_id       uuid not null,
  position     int  not null check (position >= 0),
  from_key     text not null,
  to_key       text not null,
  link_type    text not null default 'FS' check (link_type in ('FS', 'SS', 'FF', 'SF')),
  lag_days     int  not null default 0,
  primary key (schedule_id, to_key, from_key, link_type),
  check (from_key <> to_key),
  foreign key (schedule_id, org_id) references app_prj01.schedules (id, org_id) on delete cascade,
  foreign key (schedule_id, from_key) references app_prj01.schedule_items (schedule_id, key)
    on delete cascade deferrable initially deferred,
  foreign key (schedule_id, to_key) references app_prj01.schedule_items (schedule_id, key)
    on delete cascade deferrable initially deferred
);

alter table app_prj01.schedules      enable row level security;
alter table app_prj01.schedule_items enable row level security;
alter table app_prj01.schedule_links enable row level security;

create policy schedules_read on app_prj01.schedules
  for select to authenticated using (app_prj01.is_member(org_id));
create policy schedules_insert on app_prj01.schedules
  for insert to authenticated with check (app_prj01.is_member(org_id));
create policy schedules_delete on app_prj01.schedules
  for delete to authenticated using (app_prj01.is_member(org_id));

create policy schedule_items_read on app_prj01.schedule_items
  for select to authenticated using (app_prj01.is_member(org_id));
create policy schedule_items_insert on app_prj01.schedule_items
  for insert to authenticated with check (app_prj01.is_member(org_id));

create policy schedule_links_read on app_prj01.schedule_links
  for select to authenticated using (app_prj01.is_member(org_id));
create policy schedule_links_insert on app_prj01.schedule_links
  for insert to authenticated with check (app_prj01.is_member(org_id));

-- One schedule in one call, all or nothing. security invoker: it runs with the caller's rights, so
-- RLS decides; the project is looked up through RLS, so another organisation's project is "not found".
-- p_items: array of {key, name, type, parent, start, finish, duration, size, owner, status, notes, extras}
-- p_links: array of {from, to, type, lag}
create function app_prj01.import_schedule(p_project uuid, p_method text, p_source text, p_items jsonb, p_links jsonb)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  v_org uuid;
  v_id  uuid;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_typeof(p_links) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'items and links must be arrays, with at least one item' using errcode = '22023';
  end if;
  select p.org_id into v_org from app_prj01.projects p where p.id = p_project;
  if v_org is null then
    raise exception 'project not found' using errcode = '42501';
  end if;
  insert into app_prj01.schedules (org_id, project_id, method, source_name, item_count, link_count)
    values (v_org, p_project, p_method, p_source, jsonb_array_length(p_items), jsonb_array_length(p_links))
    returning id into v_id;
  insert into app_prj01.schedule_items
    (schedule_id, org_id, position, key, name, type, parent, start_date, finish_date, duration, size, owner, status, notes, extras)
  select v_id, v_org, (e.ord - 1)::int, e.v ->> 'key', e.v ->> 'name', e.v ->> 'type', nullif(e.v ->> 'parent', ''),
         (e.v ->> 'start')::date, (e.v ->> 'finish')::date, nullif(e.v ->> 'duration', ''), (e.v ->> 'size')::numeric,
         nullif(e.v ->> 'owner', ''), nullif(e.v ->> 'status', ''), nullif(e.v ->> 'notes', ''),
         coalesce(e.v -> 'extras', '{}'::jsonb)
    from jsonb_array_elements(p_items) with ordinality as e(v, ord);
  insert into app_prj01.schedule_links (schedule_id, org_id, position, from_key, to_key, link_type, lag_days)
  select v_id, v_org, (e.ord - 1)::int, e.v ->> 'from', e.v ->> 'to', coalesce(e.v ->> 'type', 'FS'),
         coalesce((e.v ->> 'lag')::int, 0)
    from jsonb_array_elements(p_links) with ordinality as e(v, ord);
  return v_id;
end;
$$;

-- forget(): same as 20261126094738_prj01_tenancy.sql, plus the schedule counts. Schedules of the
-- organisations removed go with them (cascade from projects); schedules the person imported in an
-- organisation that stays keep their rows, with imported_by set to null (on delete set null).
create or replace function app_prj01.forget(p_user uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_orgs      uuid[];
  n_orgs      int;
  n_members   int;
  n_projects  int;
  n_schedules int;
  n_items     int;
  n_links     int;
  n_unlinked  int;
  n_audit     int;
  n_cost      int;
  n_runs      int;
  n_users     int;
  v_counts    jsonb;
begin
  if p_user is null then
    raise exception 'no person given';
  end if;
  select coalesce(array_agg(m.org_id), '{}') into v_orgs
    from app_prj01.members m
   where m.user_id = p_user
     and not exists (select 1 from app_prj01.members o where o.org_id = m.org_id and o.user_id <> p_user);

  select count(*) into n_projects  from app_prj01.projects       where org_id = any (v_orgs);
  select count(*) into n_schedules from app_prj01.schedules      where org_id = any (v_orgs);
  select count(*) into n_items     from app_prj01.schedule_items where org_id = any (v_orgs);
  select count(*) into n_links     from app_prj01.schedule_links where org_id = any (v_orgs);
  select count(*) into n_unlinked  from app_prj01.schedules
   where imported_by = p_user and not (org_id = any (v_orgs));

  delete from app_prj01.members where user_id = p_user;
  get diagnostics n_members = row_count;
  delete from app_prj01.orgs where id = any (v_orgs);
  get diagnostics n_orgs = row_count;
  update app_prj01.schedules set imported_by = null where imported_by = p_user;

  update core.audit_log set tenant_id = null, detail = '{}'::jsonb,
         actor = case when actor = p_user::text then 'forgotten' else actor end
   where app = 'prj01' and (tenant_id = any (v_orgs) or actor = p_user::text);
  get diagnostics n_audit = row_count;
  update core.cost_ledger set tenant_id = null
   where app = 'prj01' and tenant_id = any (v_orgs);
  get diagnostics n_cost = row_count;
  update core.agent_runs set goal = '', steps = '[]'::jsonb, waiting_for = null, updated_at = now()
   where app = 'prj01' and tenant_id = any (v_orgs);
  get diagnostics n_runs = row_count;

  delete from auth.users where id = p_user;
  get diagnostics n_users = row_count;

  v_counts := jsonb_build_object(
    'app_prj01.orgs', n_orgs, 'app_prj01.members', n_members, 'app_prj01.projects', n_projects,
    'app_prj01.schedules', n_schedules, 'app_prj01.schedule_items', n_items, 'app_prj01.schedule_links', n_links,
    'app_prj01.schedules_unlinked', n_unlinked,
    'core.audit_log', n_audit, 'core.cost_ledger', n_cost, 'core.agent_runs', n_runs,
    'auth.users', n_users);
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj01', null, 'system', 'forget', null, v_counts);
  return v_counts;
end;
$$;

-- Grants.
revoke all on app_prj01.schedules, app_prj01.schedule_items, app_prj01.schedule_links from public, anon, authenticated;
revoke execute on function app_prj01.import_schedule(uuid, text, text, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function app_prj01.forget(uuid) from public, anon, authenticated;

grant select, insert, delete on app_prj01.schedules to authenticated;
grant select, insert on app_prj01.schedule_items, app_prj01.schedule_links to authenticated;
grant execute on function app_prj01.import_schedule(uuid, text, text, jsonb, jsonb) to authenticated;
grant execute on function app_prj01.forget(uuid) to service_role;
