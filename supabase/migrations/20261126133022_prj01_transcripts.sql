-- ai-platform: transcript drop point for prj01 (PM copilot), story prj01-R1 US-3.
-- Decision 26/11/2026 (Hub row 242): the project is matched by signal scoring in prj01
-- (lib/intake/match.js), not by a model; this table keeps the transcript, the decision and its reasons.
-- A transcript is stored with status 'matched' (the copilot was sure), 'needs_choice' (it asked the PM:
-- no project, or two) or 'confirmed' (the PM chose or confirmed the project). The same text dropped
-- twice in one organisation is refused (content fingerprint, unique per organisation).
--
-- Separation rule: org_id on every row, RLS through is_member(); the composite foreign key ties the
-- project to the same organisation. Personal data: the text can name people, so it lives only in the
-- organisation's own rows and goes with the organisation in forget(); uploaded_by is the person's key.
--
-- Who may do what:
--   anon           nothing
--   authenticated  read, add and delete transcripts of their own organisations; change only the
--                  project, status and confirmed_at (confirming the project), never the text
-- forget(): updated below to count transcripts removed and unlink those the person dropped elsewhere.

create table app_prj01.transcripts (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references app_prj01.orgs (id) on delete cascade,
  project_id      uuid,
  source_name     text not null check (length(source_name) between 1 and 300),
  content         text not null check (length(content) between 200 and 1100000),
  content_sha256  text not null check (content_sha256 ~ '^[0-9a-f]{64}$'),
  status          text not null check (status in ('matched', 'needs_choice', 'confirmed')),
  match           jsonb not null default '{}'::jsonb check (jsonb_typeof(match) = 'object'),
  uploaded_by     uuid default auth.uid() references auth.users (id) on delete set null,
  created_at      timestamptz not null default now(),
  confirmed_at    timestamptz,
  unique (org_id, content_sha256),
  check (status = 'needs_choice' or project_id is not null),
  foreign key (project_id, org_id) references app_prj01.projects (id, org_id) on delete cascade
);
create index transcripts_project on app_prj01.transcripts (project_id);

alter table app_prj01.transcripts enable row level security;

create policy transcripts_read on app_prj01.transcripts
  for select to authenticated using (app_prj01.is_member(org_id));
create policy transcripts_insert on app_prj01.transcripts
  for insert to authenticated with check (app_prj01.is_member(org_id));
create policy transcripts_update on app_prj01.transcripts
  for update to authenticated using (app_prj01.is_member(org_id)) with check (app_prj01.is_member(org_id));
create policy transcripts_delete on app_prj01.transcripts
  for delete to authenticated using (app_prj01.is_member(org_id));

-- forget(): same as 20261126123821_prj01_schedules.sql, plus the transcript counts.
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
  n_transcripts int;
  n_tr_unlinked int;
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
  select count(*) into n_transcripts from app_prj01.transcripts where org_id = any (v_orgs);
  select count(*) into n_tr_unlinked from app_prj01.transcripts
   where uploaded_by = p_user and not (org_id = any (v_orgs));

  delete from app_prj01.members where user_id = p_user;
  get diagnostics n_members = row_count;
  delete from app_prj01.orgs where id = any (v_orgs);
  get diagnostics n_orgs = row_count;
  update app_prj01.schedules set imported_by = null where imported_by = p_user;
  update app_prj01.transcripts set uploaded_by = null where uploaded_by = p_user;

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
    'app_prj01.transcripts', n_transcripts, 'app_prj01.transcripts_unlinked', n_tr_unlinked,
    'core.audit_log', n_audit, 'core.cost_ledger', n_cost, 'core.agent_runs', n_runs,
    'auth.users', n_users);
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj01', null, 'system', 'forget', null, v_counts);
  return v_counts;
end;
$$;

-- Grants.
revoke all on app_prj01.transcripts from public, anon, authenticated;
revoke execute on function app_prj01.forget(uuid) from public, anon, authenticated;

grant select, insert, delete on app_prj01.transcripts to authenticated;
grant update (project_id, status, confirmed_at) on app_prj01.transcripts to authenticated;
grant execute on function app_prj01.forget(uuid) to service_role;
