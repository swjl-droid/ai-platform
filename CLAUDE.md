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

1. **`core` is server-only.** RLS is on for every `core` table; policies exist only for the dedicated server roles (rule 7). `anon` and `authenticated` never get access to `core`. Only server code reaches it.
2. **Every schema change is a migration file** in `supabase/migrations/`. Never change the database by hand.
3. **Name each migration file from the version Supabase records:** `YYYYMMDDHHMMSS_name.sql`, read back from `supabase_migrations.schema_migrations` after applying. The repo and the database history must match.
4. **Never edit a migration that has been applied.** Fix forward with a new migration.
5. **Every migration states its grants.** A new schema or table says who may use it. Nothing uses the Supabase secret (service role) key: server code reaches `core` only through a dedicated role with the smallest rights it needs.
6. **CI must pass** (`.github/workflows/ci.yml`): it applies every migration on a throwaway Postgres 17, checks rules 1 and 3, then runs every behaviour test in `supabase/tests/`.
7. **Gateway roles:** `gateway_prj01` and `gateway_prj02` may only insert `core.cost_ledger` rows of their own app (insert-only RLS policy, no read, update or delete). The gateway never uses `INSERT ... RETURNING`. Each new right is a new migration with a behaviour test in `supabase/tests/`.

## Keys and secrets

- John stores every key himself in Vercel (project, Settings, Environment Variables, type **Sensitive**).
- Never ask for a key in chat, never write one in code, a commit, a log or the tracker.
- No variable may start with `NEXT_PUBLIC_`: Vercel sends those to visitors' browsers.
- Secrets apply to Production and Preview only, never Development.
- Names agreed:
  - `prj01`: `ANTHROPIC_API_KEY`, `VOYAGE_API_KEY`, `PLATFORM_DB_URL` (role `gateway_prj01`), `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, `LANGFUSE_BASE_URL`
  - `prj02`: `ANTHROPIC_API_KEY`, `ONEMAP_EMAIL`, `ONEMAP_PASSWORD`, `PLATFORM_DB_URL` (role `gateway_prj02`), `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, `LANGFUSE_BASE_URL`
- `PLATFORM_DB_URL` connects through the Supabase shared pooler in transaction mode (port 6543), user `<role>.wgmldytllyxzvdlvqgnq`. John sets each role's password; Claude never sees it.

## Cost and tracing (step 5)

- The gateway is shared code from this repo, built into each app (decision 23/11/2026, Hub row 192).
- Every model call goes through the gateway, which writes one `core.cost_ledger` row and one Langfuse trace per call.
- Langfuse: one project per app in John's EU account (`https://cloud.langfuse.com`).
- What a trace may contain is set per app by `TRACE_CONTENT` (decision 23/11/2026, Hub row 193):
  - `none`: cost, tokens, timing, status, error type and run id only; no prompt or answer. prj02 uses this (children's data).
  - `masked`: content with emails, phones, NRIC numbers and given names masked before sending. prj01 uses this.
  - `full`: only on preview deployments with made-up test data, never in production.
  - If the setting is missing or unknown, the gateway uses `none`.
- `core.agent_runs` caps each run with `max_steps` and `max_cost_usd`; a run that hits a cap stops with `stopped_limit`.

## Working with John

- Work one step at a time, with the sequence numbered and announced up front.
- Changes that need his decision follow his change-request method: scope, what, why, 2 or 3 options with pros and cons, a recommendation, then the decision.
- Gaps are reported as: gap, root cause, preventive measure, remediation measure.
- Dates and times in Singapore time (SGT).
- Tracking: Google Sheet "Claude agile tracker", story AIP-W1 US-7. Add a Hub row for each step done, decision or gap. Find columns by their header and never write formula columns.
- Work on a branch and open a pull request; never push straight to `main`.
