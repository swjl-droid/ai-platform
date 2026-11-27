-- ai-platform: meeting minutes for prj01 (PM copilot), story prj01-R1 US-4. PROVISIONAL VERSION: renamed
-- to the version Supabase records after John's "yes, apply" (CLAUDE.md database rule 3).
-- Minutes are drafted from a transcript by the model through the gateway (prj01 lib/minutes): content
-- holds the meeting, the numbered topics, their points and actions, each with its quotes (transcript
-- line and exact words); checks holds the code checks (quotes found, template shape). A redraft is a new
-- version; content never changes after insert. The PM approves a draft (gate mode, L1): status
-- 'approved' with their own id and the time.
--
-- Separation rule: org_id on every row, RLS through is_member(); composite foreign keys tie the
-- transcript and the project to the same organisation. Personal data: the minutes can name people, so
-- they live only in the organisation's rows and go with the organisation in forget(); created_by and
-- approved_by are the person's keys, set to null when that person is forgotten (shared work stays).
--
-- Who may do what:
--   anon           nothing
--   authenticated  read, add and delete minutes of their own organisations; change only the status,
--                  approved_by and approved_at, and only to approve as themselves
-- forget(): updated below to count minutes removed and unlink the person from minutes kept elsewhere.

alter table app_prj01.transcripts add constraint transcripts_id_org_key unique (id, org_id);

create table app_prj01.minutes (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references app_prj01.orgs (id) on delete cascade,
  transcript_id  uuid not null,
  project_id     uuid not null,
  version        int  not null default 1 check (version between 1 and 50),
  content        jsonb not null check (jsonb_typeof(content) = 'object' and jsonb_typeof(content -> 'topics') = 'array'),
  checks         jsonb not null default '{}'::jsonb check (jsonb_typeof(checks) = 'object'),
  template       text not null check (length(template) between 1 and 60),
  model          text not null check (length(model) between 1 and 80),
  status         text not null default 'draft' check (status in ('draft', 'approved')),
  created_by     uuid default auth.uid() references auth.users (id) on delete set null,
  created_at     timestamptz not null default now(),
  approved_by    uuid references auth.users (id) on delete set null,
  approved_at    timestamptz,
  unique (org_id, transcript_id, version), -- per organisation, so the rule tells nobody about another tenant's rows
  check ((status = 'approved') = (approved_at is not null)),
  foreign key (transcript_id, org_id) references app_prj01.transcripts (id, org_id) on delete cascade,
  foreign key (project_id, org_id) references app_prj01.projects (id, org_id) on delete cascade
);
create index minutes_project on app_prj01.minutes (project_id);
comment on table app_prj01.minutes is 'Drafted minutes of a transcript, every point with its quotes; approved by a member (prj01-R1 US-4)';

alter table app_prj01.minutes enable row level security;

create policy minutes_read on app_prj01.minutes
  for select to authenticated using (app_prj01.is_member(org_id));
create policy minutes_insert on app_prj01.minutes
  for insert to authenticated with check (app_prj01.is_member(org_id) and status = 'draft' and approved_by is null);
-- Approving: only a member, only as themselves; an approved row stays approved.
create policy minutes_approve on app_prj01.minutes
  for update to authenticated using (app_prj01.is_member(org_id) and status = 'draft')
  with check (app_prj01.is_member(org_id) and status = 'approved' and approved_by = auth.uid());
create policy minutes_delete on app_prj01.minutes
  for delete to authenticated using (app_prj01.is_member(org_id));

-- forget(): same as 20261126133022_prj01_transcripts.sql, plus the minutes counts and unlinks.
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
  n_minutes   int;
  n_mi_unlinked int;
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
  select count(*) into n_minutes from app_prj01.minutes where org_id = any (v_orgs);
  select count(*) into n_mi_unlinked from app_prj01.minutes
   where (created_by = p_user or approved_by = p_user) and not (org_id = any (v_orgs));

  delete from app_prj01.members where user_id = p_user;
  get diagnostics n_members = row_count;
  delete from app_prj01.orgs where id = any (v_orgs);
  get diagnostics n_orgs = row_count;
  update app_prj01.schedules set imported_by = null where imported_by = p_user;
  update app_prj01.transcripts set uploaded_by = null where uploaded_by = p_user;
  update app_prj01.minutes set created_by = null where created_by = p_user;
  update app_prj01.minutes set approved_by = null where approved_by = p_user;

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
    'app_prj01.minutes', n_minutes, 'app_prj01.minutes_unlinked', n_mi_unlinked,
    'core.audit_log', n_audit, 'core.cost_ledger', n_cost, 'core.agent_runs', n_runs,
    'auth.users', n_users);
  insert into core.audit_log (app, tenant_id, actor, action, target, detail)
    values ('prj01', null, 'system', 'forget', null, v_counts);
  return v_counts;
end;
$$;

-- Grants.
revoke all on app_prj01.minutes from public, anon, authenticated;
revoke execute on function app_prj01.forget(uuid) from public, anon, authenticated;

grant select, insert, delete on app_prj01.minutes to authenticated;
grant update (status, approved_by, approved_at) on app_prj01.minutes to authenticated;
grant execute on function app_prj01.forget(uuid) to service_role;
