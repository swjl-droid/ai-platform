#!/usr/bin/env bash
# Self-test of the separation and forget-me tests (Hub row 213): plants a leaky policy and a
# forget() that keeps the sign-in account in a copy of the migrations, on a second throwaway
# database, and requires check_migrations.sh to fail each time. Proves a green run means something.
# Needs: psql on PATH and PG* variables pointing at a server where a database can be created.
set -euo pipefail
dir="${1:-supabase/migrations}"
here="$(cd "$(dirname "$0")" && pwd)"
mutations=(
  's/for select to authenticated using (app_[a-z0-9]*\.is_member(org_id));/for select to authenticated using (true);/|a policy that lets everyone read'
  's/^  delete from auth\.users where id = p_user;/  -- planted: account kept/|a forget() that keeps the sign-in account'
  's/for select to app_prj02_bot using (app_prj02\.is_member(family_id));/for select to app_prj02_bot using (true);/|a prj02 policy that lets the bot read every family'
  's/^  delete from app_prj02\.people where id = p_person;/  -- planted: person kept/|a prj02 forget() that keeps the person'
  's/^    delete from app_prj02\.request_ctx where xact = v_xact;/    -- planted: previous context kept/|a prj02 begin_request() that keeps the previous context for an unknown account'
  's/^  if c\.person_id is distinct from r\.person_id then return/  if false then return/|a prj02 decide_change() that lets another adult say yes'
  's/^     where id = (c ->> .trip.)::uuid and family_id = r\.family_id for update;/     where id = (c ->> \x27trip\x27)::uuid for update;/|a prj02 assign_trips() that assigns a trip of another family'
  's/on app_prj02\.travel_modes for select to app_prj02_job using (app_prj02\.is_member(family_id));/on app_prj02.travel_modes for select to app_prj02_job using (true);/|a prj02 travel_modes policy that lets a job read every family'
  's/^  if (st ->> .paused.)::boolean then return; end if;/  -- planted: pause ignored/|a prj02 job_claim_due() that sends while the family is paused'
  's/^   where id = p_trip and family_id = r\.family_id and hold_state = .held.;/   where id = p_trip and hold_state = \x27held\x27;/|a prj02 release_trip() that releases a trip of another family'
  's/^  if p\.person_id is distinct from r\.person_id then return jsonb_build_object(.ok., false, .reason., .not_yours.); end if;/  -- planted: anyone may apply/|a prj02 plan_decide() that lets another adult apply the plan'
  's/for select to app_prj02_bot using (app_prj02\.is_member(family_id));$/for select to app_prj02_bot using (true);/|a prj02 policy (any table) that lets the bot read every family'
  's/^  select \* into t from app_prj02\.trips where id = p_trip and family_id = r\.family_id and who_state = .unknown.;/  select * into t from app_prj02.trips where id = p_trip and who_state = \x27unknown\x27;/|a prj02 resolve_unknown() that answers for another family'
  's/^    if v is not null and not exists (select 1 from app_prj02\.people where id = v and family_id = p_family and role = .adult.) then/    if false then/|a prj02 legs_ok() that accepts an adult of another family'
)
fail=0
for m in "${mutations[@]}"; do
  expr="${m%%|*}"; what="${m##*|}"
  work="$(mktemp -d)"; mkdir -p "$work/migrations"; cp -r "$(dirname "$dir")/tests" "$work/tests"
  for f in "$dir"/*.sql; do sed "$expr" "$f" > "$work/migrations/$(basename "$f")"; done
  if diff -rq "$dir" "$work/migrations" >/dev/null; then echo "FAIL: mutation did not apply ($what)"; fail=1; continue; fi
  db="selftest_$RANDOM"
  psql -X -q -d "${PGDATABASE:-postgres}" -c "create database $db" >/dev/null
  if PGDATABASE="$db" bash "$here/check_migrations.sh" "$work/migrations" >/dev/null 2>&1; then
    echo "FAIL: the tests passed with $what"; fail=1
  else
    echo "caught: $what"
  fi
  psql -X -q -d "${PGDATABASE:-postgres}" -c "drop database $db" >/dev/null
done
exit $fail
