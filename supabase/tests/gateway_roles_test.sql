-- Behaviour test for the gateway roles. Runs inside a transaction that is rolled back.
begin;

do $$
declare r record;
begin
  for r in select rolname, rolsuper, rolbypassrls, rolcreaterole, rolcreatedb
           from pg_roles where rolname in ('gateway_prj01', 'gateway_prj02') loop
    if r.rolsuper or r.rolbypassrls or r.rolcreaterole or r.rolcreatedb then
      raise exception '% has too many powers', r.rolname;
    end if;
  end loop;
  if (select count(*) from pg_roles where rolname in ('gateway_prj01', 'gateway_prj02')) <> 2 then
    raise exception 'gateway roles missing';
  end if;
end $$;

-- prj01 may insert its own row (no RETURNING).
set local role gateway_prj01;
insert into core.cost_ledger (app, provider, model, purpose, input_tokens, output_tokens, cost_usd, ok)
values ('prj01', 'anthropic', 'test-model', 'ci-test', 10, 5, 0.0001, true);
reset role;

-- Each forbidden action must fail; each runs in its own savepoint.
do $$
declare
  attempts text[][] := array[
    ['gateway_prj01', 'insert into core.cost_ledger (app, provider, model, purpose) values (''prj02'', ''x'', ''x'', ''x'')', 'prj01 writing a prj02 row'],
    ['gateway_prj02', 'insert into core.cost_ledger (app, provider, model, purpose) values (''prj01'', ''x'', ''x'', ''x'')', 'prj02 writing a prj01 row'],
    ['gateway_prj01', 'select count(*) from core.cost_ledger', 'prj01 reading cost rows'],
    ['gateway_prj01', 'update core.cost_ledger set cost_usd = 0', 'prj01 changing cost rows'],
    ['gateway_prj01', 'delete from core.cost_ledger', 'prj01 deleting cost rows'],
    ['gateway_prj01', 'insert into core.cost_ledger (app, provider, model, purpose, at) values (''prj01'', ''x'', ''x'', ''x'', now() - interval ''1 day'')', 'prj01 back-dating a row'],
    ['gateway_prj01', 'insert into core.audit_log (app, actor, action) values (''prj01'', ''x'', ''x'')', 'prj01 writing the audit log'],
    ['gateway_prj01', 'insert into core.agent_runs (app, tenant_id, goal) values (''prj01'', gen_random_uuid(), ''x'')', 'prj01 writing agent runs']
  ];
  i int;
  allowed boolean;
begin
  for i in 1 .. array_length(attempts, 1) loop
    allowed := false;
    begin
      execute format('set local role %I', attempts[i][1]);
      execute attempts[i][2];
      allowed := true;
      reset role;
    exception when others then
      reset role;
    end;
    if allowed then
      raise exception 'Not blocked: %', attempts[i][3];
    end if;
  end loop;
end $$;

rollback;
