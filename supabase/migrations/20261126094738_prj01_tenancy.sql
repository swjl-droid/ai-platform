-- ai-platform: first tenant tables of prj01 (PM copilot), story prj01-R1 US-1 (sign-in, separation,
-- sample programme) and Hub row 213 (platform plan conditions 2 and 3, Hub row 211).
--
-- Separation rule (CLAUDE.md, "Tenant separation"): every table in an app schema carries the tenant
-- key (org_id for prj01) and has RLS on with a policy that limits a signed-in user to the
-- organisations they are a member of. The table that defines the tenant (orgs) is marked
-- 'tenant root' in its comment.
--
-- Who may do what:
--   anon           nothing in app_prj01
--   authenticated  read their orgs and memberships; read and change projects of their orgs;
--                  call start_sample() (own copy of the synthetic sample programme) and forget_me()
--   service_role / postgres  forget(user) for a request received another way
-- core stays server-only: the functions below reach it as their owner (security definer),
-- never through a grant to authenticated.

create table app_prj01.orgs (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(name) between 1 and 200),
  is_sample   boolean not null default false,
  created_at  timestamptz not null default now()
);
comment on table app_prj01.orgs is 'tenant root: one row per organisation; its id is the org_id of every other prj01 table';

create table app_prj01.members (
  org_id      uuid not null references app_prj01.orgs (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  role        text not null default 'member' check (role in ('owner', 'member')),
  created_at  timestamptz not null default now(),
  primary key (org_id, user_id)
);
create index members_user on app_prj01.members (user_id);

create table app_prj01.projects (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references app_prj01.orgs (id) on delete cascade,
  name         text not null check (length(name) between 1 and 200),
  methodology  text not null check (methodology in ('PMI-PMBOK', 'PRINCE2', 'Agile', 'Hybrid')),
  summary      text not null default '',
  start_date   date,
  end_date     date,
  is_sample    boolean not null default false,
  created_at   timestamptz not null default now(),
  check (end_date is null or start_date is null or end_date >= start_date)
);
create index projects_org on app_prj01.projects (org_id);

-- Membership check used by every policy. security definer so the policy on members does not
-- call itself; search_path empty so nothing can be swapped in.
create function app_prj01.is_member(p_org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from app_prj01.members m where m.org_id = p_org and m.user_id = auth.uid()
  );
$$;

alter table app_prj01.orgs     enable row level security;
alter table app_prj01.members  enable row level security;
alter table app_prj01.projects enable row level security;

create policy orgs_read on app_prj01.orgs
  for select to authenticated using (app_prj01.is_member(id));

create policy members_read on app_prj01.members
  for select to authenticated using (user_id = auth.uid() or app_prj01.is_member(org_id));

create policy projects_read on app_prj01.projects
  for select to authenticated using (app_prj01.is_member(org_id));
create policy projects_insert on app_prj01.projects
  for insert to authenticated with check (app_prj01.is_member(org_id));
create policy projects_update on app_prj01.projects
  for update to authenticated using (app_prj01.is_member(org_id)) with check (app_prj01.is_member(org_id));
create policy projects_delete on app_prj01.projects
  for delete to authenticated using (app_prj01.is_member(org_id));

-- Sample programme: each new user gets their own organisation holding 3 synthetic projects,
-- so trying the copilot never shows anyone else's data. Calling it again does nothing.
create function app_prj01.start_sample() returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_org  uuid;
begin
  if v_user is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  select m.org_id into v_org from app_prj01.members m where m.user_id = v_user limit 1;
  if v_org is not null then
    return v_org;
  end if;
  insert into app_prj01.orgs (name, is_sample) values ('Sample programme (synthetic data)', true)
    returning id into v_org;
  insert into app_prj01.members (org_id, user_id, role) values (v_org, v_user, 'owner');
  insert into app_prj01.projects (org_id, name, methodology, summary, start_date, end_date, is_sample) values
    (v_org, 'Clinic relocation', 'PMI-PMBOK',
     'Move a 40-staff outpatient clinic to a new building with no gap in appointments. Synthetic.',
     date '2026-11-02', date '2027-03-26', true),
    (v_org, 'Regional office fit-out', 'PRINCE2',
     'Fit out a 2-floor regional office: design, contractor, IT and move-in stages. Synthetic.',
     date '2026-10-05', date '2027-02-19', true),
    (v_org, 'Customer self-service portal', 'Agile',
     'Release a customer portal in 2-week sprints: sign-in, bills, service requests. Synthetic.',
     date '2026-11-16', date '2027-04-30', true);
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj01', v_org, v_user::text, 'start_sample', 'app_prj01.orgs', jsonb_build_object('projects', 3));
  return v_org;
end;
$$;

-- Forget me (CLAUDE.md "Forget me", rules 1-5). Lists every table that holds prj01 personal data;
-- a new such table is added here in the same pull request.
--   app rows: memberships deleted; organisations the person was the only member of deleted with
--             everything in them (projects cascade)
--   core.audit_log / core.cost_ledger: rows kept for accounting, link removed (tenant_id null,
--             detail emptied, actor anonymised)
--   core.agent_runs: steps, goal and waiting_for emptied
--   auth.users: the sign-in account deleted
--   the request is logged with counts only.
create function app_prj01.forget(p_user uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_orgs     uuid[];
  n_orgs     int;
  n_members  int;
  n_projects int;
  n_audit    int;
  n_cost     int;
  n_runs     int;
  n_users    int;
  v_counts   jsonb;
begin
  if p_user is null then
    raise exception 'no person given';
  end if;
  -- Organisations that would be left with no member.
  select coalesce(array_agg(m.org_id), '{}') into v_orgs
    from app_prj01.members m
   where m.user_id = p_user
     and not exists (select 1 from app_prj01.members o where o.org_id = m.org_id and o.user_id <> p_user);

  select count(*) into n_projects from app_prj01.projects where org_id = any (v_orgs);
  delete from app_prj01.members where user_id = p_user;
  get diagnostics n_members = row_count;
  delete from app_prj01.orgs where id = any (v_orgs);
  get diagnostics n_orgs = row_count;

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
    'core.audit_log', n_audit, 'core.cost_ledger', n_cost, 'core.agent_runs', n_runs,
    'auth.users', n_users);
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj01', null, 'system', 'forget', null, v_counts);
  return v_counts;
end;
$$;

-- A signed-in person can forget themselves.
create function app_prj01.forget_me() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  return app_prj01.forget(auth.uid());
end;
$$;

-- Grants.
revoke all on schema app_prj01 from public, anon;
revoke all on all tables in schema app_prj01 from public, anon, authenticated;
revoke execute on function app_prj01.is_member(uuid), app_prj01.start_sample(),
  app_prj01.forget(uuid), app_prj01.forget_me() from public, anon, authenticated;

grant usage on schema app_prj01 to authenticated, service_role;
grant select on app_prj01.orgs, app_prj01.members to authenticated;
grant select, insert, update, delete on app_prj01.projects to authenticated;
grant execute on function app_prj01.is_member(uuid), app_prj01.start_sample(), app_prj01.forget_me()
  to authenticated;
grant execute on function app_prj01.forget(uuid) to service_role;
