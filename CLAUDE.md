# ai-platform: rules for every session

This repo is the shared platform for John's AI builds. Read this before changing anything.

## What lives where (ADR-03)

- **ai-platform (this repo):** shared database schema and migrations, the LLM gateway (`gateway/`, step 5), shared rules.
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
- **Source once, stamped copies (decision 25/11/2026, Hub row 217):** the only source is `gateway/` here.
  Each app in `gateway.apps.json` holds a copy in `lib/gateway` with a `STAMP.json` (version, commit,
  SHA-256 of every file); the app's CI fails if the copy differs from its stamp. Never edit a copy:
  change `gateway/`, bump `gateway/VERSION` (CI checks this), merge, then open the copy pull requests
  with `node scripts/gateway/open-copy-prs.mjs <work-dir>`. A new app is one line in `gateway.apps.json`.
- **Copy route A+, safeguards against forgetting (decision 25/11/2026, Hub row 220).** No token opens
  pull requests across repos, so:
  1. **Same session:** the session that opens a gateway pull request opens the copy pull requests right
     after John merges it, and does not report the step done until both copies are merged.
  2. **Hub action:** when a gateway pull request opens, add a Hub `Action` "Copy gateway x.y.z into
     <apps>", Owner John + Claude, ETA = merge day + 1, with the links; close it (and the reminder issue)
     only after checking both copies are merged and each app's newest Langfuse trace shows the new tag.
  3. **Daily nudge:** `.github/workflows/gateway-release.yml` comments on and labels `overdue` any
     "Copy gateway" reminder open for more than a day (08:47 SGT; GitHub e-mails John).
  4. **Version tag:** every trace carries `gateway:<version>` (from `gateway/VERSION`).
  Revisit a token (option B) once branch protection is decided (Hub row 214) and a third app or a
  second person arrives (AIP-W2 US-1).
- **Only priced models:** the gateway refuses a model missing from `gateway/pricing.js`. Add the model
  with its price and source date before using it.
- **Certificate checked:** the gateway trusts only Supabase Root 2021 CA (`gateway/supabase-root-2021.crt`,
  fingerprint pinned in a test) and ignores any `sslmode` in `PLATFORM_DB_URL`. Never set
  `rejectUnauthorized: false`; a test fails if anyone does (Hub row 204).
- A failed ledger insert or trace never fails the model call; the result says what was logged
  (`logged.ledger`, `logged.trace`) and the error kind (never the content or a key) goes to the function log.
- Every model call goes through the gateway, which writes one `core.cost_ledger` row and one Langfuse trace per call.
- Langfuse: one project per app in John's EU account (`https://cloud.langfuse.com`).
- What a trace may contain is set per app by `TRACE_CONTENT` (decision 23/11/2026, Hub row 193):
  - `none`: cost, tokens, timing, status, error type and run id only; no prompt or answer. prj02 uses this (children's data).
  - `masked`: content with emails, phones, NRIC numbers and given names masked before sending. prj01 uses this.
  - `full`: only on preview deployments with made-up test data, never in production.
  - If the setting is missing or unknown, the gateway uses `none`.
- `core.agent_runs` caps each run with `max_steps` and `max_cost_usd`; a run that hits a cap stops with `stopped_limit`.

## Secret scan (platform plan condition 1, decision 25/11/2026, Hub row 211)

- CI in ai-platform, prj01 and prj02 runs `scripts/ci/secret_scan.sh`: gitleaks (pinned image) over
  every commit, then a self-test that plants a fake key in a throwaway folder and requires the scan to
  catch it. A red secret scan blocks the merge. A real key found in history is revoked first, then removed.

## Lint (AIP-W1 US-7, decision 25/11/2026, Hub row 226)

- CI in ai-platform, prj01 and prj02 runs `scripts/ci/lint.sh`: ESLint (pinned, recommended rules,
  `eslint.config.js`) over the repo, then a self-test with planted mistakes that must fail. A red lint
  blocks the merge. The apps do not lint `lib/gateway` (it is linted here, at its source).

## Forget me (platform plan condition 2, decision 25/11/2026, Hub row 211)

When a person asks to be forgotten, everything that identifies them is deleted or made anonymous,
in every place the platform keeps it, and the request itself is recorded without their personal data.

1. **Every table that holds personal data** has the person's key (`tenant_id`, `family_id`, `org_id` or a
   user id) so their rows can be found. No personal data in a table without such a key.
2. **One forget function per app** (`forget(personId)`) lists every table it clears; a new table with
   personal data is added to it in the same pull request.
3. **What happens to shared rows:** app rows are deleted; `core.audit_log` and `core.cost_ledger` keep
   the row for accounting but lose the link (`tenant_id` set to null, `detail` emptied);
   `core.agent_runs` steps and goals are emptied.
4. **Langfuse:** traces carry the person's id as `userId` (never a name), so their traces can be found and
   deleted in Langfuse. The gateway's keys cannot delete; John deletes them in Langfuse (or with a
   short-lived admin key he creates and removes the same day).
5. **Audit:** the request is logged in `core.audit_log` with action `forget`, the date and the counts
   removed per table; no name, email or content.
6. **CI test:** a forget-me test (create a person, add data everywhere, forget, check nothing is left)
   ships in the same pull request as the first family or organisation table (condition 2).
7. The time limit for answering a request is set in each app's privacy notice; backups follow
   Supabase's retention.

## Working with John

- Work one step at a time, with the sequence numbered and announced up front.
- Changes that need his decision follow his change-request method: scope, what, why, 2 or 3 options with pros and cons, a recommendation, then the decision.
- Gaps are reported as: gap, root cause, preventive measure, remediation measure.
- Dates and times in Singapore time (SGT).
- Tracking: Google Sheet "Claude agile tracker", story AIP-W1 US-7. Add a Hub row for each step done, decision or gap. Find columns by their header and never write formula columns.
- Work on a branch and open a pull request; never push straight to `main`.
