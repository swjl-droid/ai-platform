-- ai-platform: shared core schema (ADR-01 option B, decided by John 20/11/2026).
-- core holds only what every app shares: audit_log, cost_ledger, agent_runs.
-- Each app keeps its own tenancy in its own schema (app_prj01, app_prj02), created empty here.
-- core is server-only: RLS on, no policies for anon / authenticated; the platform's server code
-- (service role) writes and reads it.

create schema if not exists core;
create schema if not exists app_prj01;
create schema if not exists app_prj02;

revoke all on schema core from anon, authenticated;

create table core.audit_log (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  app         text not null check (app in ('platform', 'prj01', 'prj02')),
  tenant_id   uuid,
  actor       text not null,
  action      text not null,
  target      text,
  detail      jsonb not null default '{}'::jsonb
);
create index audit_log_app_tenant_at on core.audit_log (app, tenant_id, at desc);

create table core.cost_ledger (
  id             bigint generated always as identity primary key,
  at             timestamptz not null default now(),
  app            text not null check (app in ('platform', 'prj01', 'prj02')),
  tenant_id      uuid,
  provider       text not null,
  model          text not null,
  purpose        text not null,
  input_tokens   integer not null default 0 check (input_tokens >= 0),
  output_tokens  integer not null default 0 check (output_tokens >= 0),
  cache_read_tokens  integer not null default 0 check (cache_read_tokens >= 0),
  cache_write_tokens integer not null default 0 check (cache_write_tokens >= 0),
  cost_usd       numeric(12, 6) not null default 0 check (cost_usd >= 0),
  latency_ms     integer,
  agent_run_id   uuid,
  trace_id       text,
  ok             boolean not null default true
);
create index cost_ledger_app_tenant_at on core.cost_ledger (app, tenant_id, at desc);

create table core.agent_runs (
  id           uuid primary key default gen_random_uuid(),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  app          text not null check (app in ('prj01', 'prj02')),
  tenant_id    uuid not null,
  goal         text not null,
  status       text not null default 'running'
               check (status in ('running', 'waiting_approval', 'done', 'stopped_limit', 'failed', 'cancelled')),
  steps        jsonb not null default '[]'::jsonb,
  step_count   integer not null default 0 check (step_count >= 0),
  cost_usd     numeric(12, 6) not null default 0 check (cost_usd >= 0),
  max_steps    integer not null default 8,
  max_cost_usd numeric(12, 6) not null default 0.50,
  waiting_for  jsonb,
  trace_id     text
);
create index agent_runs_app_tenant_status on core.agent_runs (app, tenant_id, status);

alter table core.audit_log   enable row level security;
alter table core.cost_ledger enable row level security;
alter table core.agent_runs  enable row level security;