# ai-platform: rules for every session

This repo is the shared platform for John's AI builds. Read this before changing anything.

## What lives where (ADR-03)

- **ai-platform (this repo):** shared database schema and migrations, the LLM gateway (step 5), shared rules.
- **prj01:** PM copilot. Vercel project `prj01` (team `swjl`).
- **prj02:** Family orchestrator. Vercel project `prj02` (team `swjl`).

## Decisions

- **ADR-01, one database:** one shared Supabase project `ai-platform` (ref `wgmldytllyxzvdlvqgnq`, Singapore). One schema per app (`app_prj01`, `app_prj02`). The shared `core` schema holds only `audit_log`, `cost_ledger` and `agent_runs`.
- **ADR-02, Vercel functions:** app logic runs as Vercel functions in region `sin1`. An agent that needs a human yes sets its `core.agent_runs` row to `waiting_approval`, stops, and resumes from that row after the yes.
- **ADR-03, repos:** one platform repo plus one repo per build.

## Database rules

1. **`core` is server-only.** RLS is on for every `core` table, with no policies. `anon` and `authenticated` never get access to `core`. Only server code reaches it.
2. **Every schema change is a migration file** in `supabase/migrations/`. Never change the database by hand.
3. **Name each migration file from the version Supabase records:** `YYYYMMDDHHMMSS_name.sql`, read back from `supabase_migrations.schema_migrations` after applying. The repo and the database history must match.
4. **Never edit a migration that has been applied.** Fix forward with a new migration.
5. **Every migration states its grants.** A new schema or table says who may use it; `service_role` access to `core` comes with the step 5 gateway migration.
6. **CI must pass** (`.github/workflows/ci.yml`): it applies every migration on a throwaway Postgres 17 and checks rules 1, 3 and 5's lock-out.

## Keys and secrets

- John stores every key himself in Vercel (project, Settings, Environment Variables, type **Sensitive**).
- Never ask for a key in chat, never write one in code, a commit, a log or the tracker.
- Names agreed:
  - `prj01`: `ANTHROPIC_API_KEY`, `VOYAGE_API_KEY`
  - `prj02`: `ANTHROPIC_API_KEY`, `ONEMAP_EMAIL`, `ONEMAP_PASSWORD`

## Cost and tracing (step 5)

- Every model call goes through the gateway, which writes one `core.cost_ledger` row and one Langfuse trace per call.
- `core.agent_runs` caps each run with `max_steps` and `max_cost_usd`; a run that hits a cap stops with `stopped_limit`.

## Working with John

- Work one step at a time, with the sequence numbered and announced up front.
- Changes that need his decision follow his change-request method: scope, what, why, 2 or 3 options with pros and cons, a recommendation, then the decision.
- Gaps are reported as: gap, root cause, preventive measure, remediation measure.
- Dates and times in Singapore time (SGT).
- Tracking: Google Sheet "Claude agile tracker", story AIP-W1 US-7. Add a Hub row for each step done, decision or gap. Find columns by their header and never write formula columns.
- Work on a branch and open a pull request; never push straight to `main`.
