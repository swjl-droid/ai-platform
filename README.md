# ai-platform

Shared platform for John's AI builds (ADR-03: one platform repo, plus one repo per build).

- **This repo:** the shared database schema (Supabase `core`), the LLM gateway and the rules every build follows.
- **Builds:** `prj01` (PM copilot) and `prj02` (Family orchestrator), each in its own repo.

Decisions:

- **ADR-01:** one shared Supabase database, one schema per app. The shared `core` schema holds `audit_log`, `cost_ledger` and `agent_runs`.
- **ADR-02:** app logic runs as Vercel functions (region `sin1`). `agent_runs` lets an agent pause for a human yes and resume.
- **ADR-03:** one platform repo plus one repo per build.
