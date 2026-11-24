-- ai-platform: insert-only database roles for the LLM gateway (decisions 23/11/2026:
-- step 5.1 option B, Hub row 191; step 5.2 shared code in each app, Hub row 192).
-- Each app's gateway writes one core.cost_ledger row per model call and nothing else:
--   * no password here: John sets it in the Supabase SQL editor, so no secret is in git
--   * no BYPASSRLS, no read, update or delete, no other table, no app schema
--   * an insert-only RLS policy limits each role to rows of its own app
--   * id and at are filled by the database, so rows cannot be back-dated
-- The gateway must not use INSERT ... RETURNING (that would need read access).

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'gateway_prj01') then
    create role gateway_prj01 login noinherit nobypassrls connection limit 10;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'gateway_prj02') then
    create role gateway_prj02 login noinherit nobypassrls connection limit 10;
  end if;
end $$;

alter role gateway_prj01 set statement_timeout = '5s';
alter role gateway_prj02 set statement_timeout = '5s';

grant usage on schema core to gateway_prj01, gateway_prj02;

grant insert (app, tenant_id, provider, model, purpose,
              input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
              cost_usd, latency_ms, agent_run_id, trace_id, ok)
  on core.cost_ledger to gateway_prj01, gateway_prj02;

create policy cost_ledger_insert_prj01 on core.cost_ledger
  for insert to gateway_prj01 with check (app = 'prj01');
create policy cost_ledger_insert_prj02 on core.cost_ledger
  for insert to gateway_prj02 with check (app = 'prj02');