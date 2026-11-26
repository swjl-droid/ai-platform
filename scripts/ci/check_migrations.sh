#!/usr/bin/env bash
# Rehearses every migration on a throwaway Postgres and checks the rules in CLAUDE.md.
# Needs: psql on PATH, and PG* environment variables pointing at an empty database.
# Usage: scripts/ci/check_migrations.sh [migrations_dir]
# Behaviour tests: every .sql file in the sibling tests/ folder runs after the migrations
# and must finish without error (each test rolls itself back).
set -euo pipefail

dir="${1:-supabase/migrations}"
psql_q() { psql -v ON_ERROR_STOP=1 -X -q "$@"; }

echo "== 1. File names"
shopt -s nullglob
files=("$dir"/*.sql)
if [ ${#files[@]} -eq 0 ]; then
  echo "No migrations found in $dir"; exit 1
fi
bad=0
for f in "${files[@]}"; do
  name="$(basename "$f")"
  # <14-digit version>_<lower_snake_name>.sql; the version is the one Supabase records.
  if [[ ! "$name" =~ ^[0-9]{14}_[a-z0-9_]+\.sql$ ]]; then
    echo "  bad name: $name (expected YYYYMMDDHHMMSS_name.sql)"; bad=1
  fi
done
dupes="$(for f in "${files[@]}"; do basename "$f" | cut -c1-14; done | sort | uniq -d)"
if [ -n "$dupes" ]; then
  echo "  duplicate versions: $dupes"; bad=1
fi
[ "$bad" -eq 0 ] || exit 1
echo "  ${#files[@]} file(s) named correctly"

echo "== 2. Supabase roles (stand-ins for the hosted ones)"
psql_q <<'SQL'
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;
-- Hosted Supabase grants these on public by default; mirror that so revokes are tested.
grant usage on schema public to anon, authenticated, service_role;
-- Supabase Auth stand-in: auth.users and auth.uid() as the hosted project has them. auth.uid()
-- reads the signed-in user from request.jwt.claims, the setting PostgREST fills from the token.
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key, email text);
create or replace function auth.uid() returns uuid language sql stable as $f$
  select nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', '')::uuid
$f$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
SQL

echo "== 3. Apply migrations in order"
for f in $(printf '%s\n' "${files[@]}" | sort); do
  echo "  $(basename "$f")"
  psql_q -1 -f "$f"
done

echo "== 4. Rules"
psql_q <<'SQL'
do $$
declare
  r record;
  failures text := '';
begin
  -- core is server-only: app users get no access to the schema.
  for r in select unnest(array['anon', 'authenticated']) as role loop
    if has_schema_privilege(r.role, 'core', 'USAGE') then
      failures := failures || format(E'\n  %s has USAGE on schema core', r.role);
    end if;
  end loop;
  -- Every table in core has row level security on.
  for r in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'core' and c.relkind = 'r' and not c.relrowsecurity
  loop
    failures := failures || format(E'\n  core.%s has RLS off', r.relname);
  end loop;
  -- The three shared tables of ADR-01 exist.
  for r in select unnest(array['audit_log', 'cost_ledger', 'agent_runs']) as t loop
    if to_regclass('core.' || r.t) is null then
      failures := failures || format(E'\n  core.%s is missing', r.t);
    end if;
  end loop;
  -- Tenant separation (CLAUDE.md): every table in an app schema has RLS on, at least one
  -- policy, and the tenant key (org_id or family_id), unless its comment marks it 'tenant root'.
  -- anon gets nothing in an app schema.
  for r in
    select n.nspname, c.relname, c.oid, c.relrowsecurity
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname like 'app\_%' and c.relkind in ('r', 'p')
  loop
    if not r.relrowsecurity then
      failures := failures || format(E'\n  %s.%s has RLS off', r.nspname, r.relname);
    end if;
    if not exists (select 1 from pg_policy p where p.polrelid = r.oid) then
      failures := failures || format(E'\n  %s.%s has no RLS policy', r.nspname, r.relname);
    end if;
    if not exists (select 1 from pg_attribute a where a.attrelid = r.oid and not a.attisdropped
                   and a.attname in ('org_id', 'family_id'))
       and coalesce(obj_description(r.oid, 'pg_class'), '') not like 'tenant root%' then
      failures := failures || format(E'\n  %s.%s has no org_id or family_id', r.nspname, r.relname);
    end if;
  end loop;
  for r in select nspname from pg_namespace where nspname like 'app\_%' loop
    if has_schema_privilege('anon', r.nspname, 'USAGE') then
      failures := failures || format(E'\n  anon has USAGE on schema %s', r.nspname);
    end if;
  end loop;
  if failures <> '' then
    raise exception 'Rule check failed:%', failures;
  end if;
end $$;
SQL
echo "  core is server-only, RLS is on, the shared tables exist; app tables are separated by tenant"

echo "== 5. Behaviour tests"
tests_dir="$(dirname "$dir")/tests"
tests=("$tests_dir"/*.sql)
if [ ${#tests[@]} -eq 0 ]; then
  echo "  none found in $tests_dir"
else
  for t in $(printf '%s\n' "${tests[@]}" | sort); do
    echo "  $(basename "$t")"
    psql_q -f "$t"
  done
fi
echo "All checks passed"
