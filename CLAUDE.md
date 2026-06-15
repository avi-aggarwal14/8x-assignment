# CLAUDE.md — agent working notes & coordination

> **Read this first if you're an agent (Claude Code / Codex / Cursor) landing on
> this repo.** It tells you what the assignment is, what's already been done, what
> is still open, and the conventions to follow so parallel agents don't collide.
>
> For a full map of the codebase, read [`ARCHITECTURE.md`](./ARCHITECTURE.md).
> For the assignment rules, read [`README.md`](./README.md).

---

## ⚠️ Operating rules for every agent (MANDATORY)

These apply to **every** agent (Claude Code, Codex, Cursor, subagents) on **every**
task in this repo. They are non-negotiable:

1. **Read first, always.** Before starting *any* task, read both this file
   (`CLAUDE.md`) and [`ARCHITECTURE.md`](./ARCHITECTURE.md) in full, and keep both
   in your working context for the entire task. They are the shared source of
   truth for what the repo is and what other agents have already done.
2. **Document meaningful contributions immediately.** Whenever you make a
   meaningful change — fix a bug, change behaviour, add/modify a file, reach a
   Part 2 conclusion, or finish a workstream — update `CLAUDE.md` (the **status
   board** below + relevant notes) and/or `ARCHITECTURE.md` (the affected section)
   in the *same* change set. A contribution isn't done until these docs reflect it.
   - "Meaningful" = anything another agent would need to know to avoid duplicating
     or conflicting with your work. Trivial typo/whitespace fixes are exempt.
   - Keep edits surgical and factual: what changed, where, why, current status.
3. **Claim before you touch.** Mark your workstream on the status board before
   starting so parallel agents don't collide.

---

## What this repo is

A **timed engineering assignment** built on a slice of the "8x" creator-payments
production codebase. It is meant to be **read and navigated**, not booted in full
(the web server needs Supabase + Stripe, which aren't provided). Only two things
run locally:

- **Part 1 — unit tests** (`pnpm test`) — verified locally.
- **Part 2 — a local Postgres slice** (`cd ASSIGNMENT && docker compose up -d`,
  Postgres on `localhost:5433`) — verified against the seeded DB.

There are **two parts**:

- **Part 1 — Bugs:** three small, self-contained backend bugs in `lib/`, each
  caught by a failing unit test.
- **Part 2 — Investigation:** one tangled creator-pay problem surfacing as three
  support tickets ([`TICKETS.md`](./TICKETS.md)); write-up goes in
  [`FINDINGS.md`](./FINDINGS.md).

---

## Status board

> **Last full codebase→docs reconciliation: 2026-06-15.** On request, an agent
> sweeps the whole repo (recently-modified files outside `node_modules`) for
> changes or artifacts left undocumented and folds them into this file /
> `ARCHITECTURE.md`, so this board always reflects reality. If you make a change,
> update the board yourself rather than waiting for a sweep.

| Workstream | Status | Owner / notes |
|---|---|---|
| **Part 1 — bug #1 rate limiter** | ✅ **DONE** | `lib/modules/phone-verification/rate-limit.ts` |
| **Part 1 — bug #2 lookup classifier** | ✅ **DONE** | `lib/admin/lookup/classify.ts` |
| **Part 1 — bug #3 CPM earnings** | ✅ **DONE** | `lib/modules/cpm/utils.ts` |
| **Part 1 — test suite** | ✅ **GREEN** | `pnpm test` → 98/98 passing |
| **Part 2 — reproduce tickets vs DB** | ✅ **DONE** | reproduced against live seed; queries + output quoted in `FINDINGS.md` |
| **Part 2 — root-cause analysis** | ✅ **DONE** | all 3 tickets root-caused in `FINDINGS.md` (stale `managed_creators` copy: wrong base-pay value + legacy milestone JSON shape; 3 unreconciled stores) |
| **Part 2 — `FINDINGS.md` write-up** | ✅ **DONE** | fully written (source-of-truth table, per-ticket root cause, fix direction, before/after) |
| **Part 2 — demonstration migration** | ✅ **DONE** | `ASSIGNMENT/db/migrations/0001_fix_payment_source_of_truth.sql` — idempotent fix; **not** auto-loaded (subdir), apply manually (see Part 2 section) |
| **`SUMMARY.md`** | ⬜ **OPEN** | required at submission (see `README.md` §Submitting) |
| **`pnpm logs:capture` + commit logs** | ⬜ **OPEN** | run once before submit; commit `.claude-logs/` |

> **Update this board** when you pick up or finish a workstream so other agents
> don't duplicate effort.

---

## Part 1 — what was done (DONE ✅)

Three logic-level fixes, **no test files touched** (a hidden suite re-runs these
modules at grading time, so the fixes target real behaviour, not assertions):

1. **Rate limiter** — `lib/modules/phone-verification/rate-limit.ts`
   Off-by-one let a limit of N admit N+1. The first request seeds `count: 1` and
   each allowed call increments, so the guard must be strict.
   **Fix:** `if (entry.count <= maxAttempts)` → `if (entry.count < maxAttempts)`.

2. **Lookup classifier** — `lib/admin/lookup/classify.ts`
   The ad-code regex only matched 4–5 chars, but the module's own docstring says
   codes are 4–12 chars; 6-char codes (`ABC123`, `ABCDEF`) wrongly fell through
   to `username`.
   **Fix:** `AD_CODE_RE = /^[A-Z0-9]{4,5}$/` → `/^[A-Z0-9]{4,12}$/`.

3. **CPM earnings** — `lib/modules/cpm/utils.ts`
   CPM = cost per **1,000** views, but the math divided by `10000`, making every
   payout 10× too small.
   **Fix:** `(views / 10000) * cpmRate` → `(views / 1000) * cpmRate`.

Verify: `pnpm test` → **98/98 passing** (3 test files: `rate-limit.test.ts`,
`classify.test.ts`, `cpm/__tests__/utils.test.ts`).

---

## Part 2 — the investigation (analysis DONE; see `FINDINGS.md`)

> **Status:** the investigation is complete and written up in
> [`FINDINGS.md`](./FINDINGS.md), and a demonstration migration has been written
> (`ASSIGNMENT/db/migrations/0001_fix_payment_source_of_truth.sql`). The summary
> below remains as orientation; the authoritative write-up is `FINDINGS.md`.
>
> **What the migration does** (idempotent; apply manually — it is in a subdir so
> the Postgres entrypoint does **not** auto-run it on a fresh boot):
> 1. Sources `base_pay_cents` + `bonus_milestones` from `brand_campaigns` (joined
>    via `managed_creators.job_id`), with `managed_creators` as explicit fallback.
> 2. Normalizes milestone JSON to canonical `{min_views, amount_cents}` and reads
>    it key-tolerantly (still accepts legacy `{views, bonus_cents}` in transition).
> 3. Projects `total_paid_cents` / `payment_status` from `creator_transactions`
>    via a new `trigger_sync_post_paid` (AFTER INSERT/UPDATE/DELETE).
> 4. Backfills + recomputes every existing post.
>
> ```bash
> docker exec -i assignment_db psql -U postgres -d assignment \
>   < ASSIGNMENT/db/migrations/0001_fix_payment_source_of_truth.sql
> ```
> Verified before/after: Maria $1→$60 owed (bonus restored), Teo flips `paid`→
> `partially_paid` ($5 of $60). The forward checks mutated the throwaway
> container — `docker compose down -v && docker compose up -d` for a clean seed.

The investigation. Don't start by editing code — start by **reproducing the
tickets against the database**, then **trace each number to the trigger/column
that produced it**. The seed deliberately plants the mismatches.

Pointers (full detail in `ARCHITECTURE.md` §7–8 and §13):

- **Two pay systems:** CPM submissions (`cpm_submissions`, `lib/modules/cpm/*`)
  vs managed creator posts (`managed_creator_posts`, frozen by DB triggers).
- **Three disagreeing "totals":** admin panel reads the frozen
  `managed_creator_posts.*_cents` snapshot; creator wallet reads the
  `creator_transactions` ledger; brand report reads `brand_campaigns` config.
  Nothing reconciles them → TICKET-490.
- **The triggers live in `ASSIGNMENT/db/init.sql`:**
  `create_managed_creator_post()` (AFTER INSERT ON `posts`) freezes the snapshot;
  `recalculate_managed_creator_post_payment()` (AFTER INSERT ON
  `post_engagement_metrics`) recomputes from the **already-frozen** copies, so it
  can't heal a bad initial snapshot.
- **The planted mismatches (from `seed.sql`):**
  - `base_pay` is cents-in-a-NUMERIC, confused with dollars → the **$1 payout
    (TICKET-481)**.
  - Two bonus-milestone JSONB shapes coexist (`{min_views, amount_cents}` vs
    legacy `{views, bonus_cents}`); the trigger reads the new keys and gets NULL
    on legacy rows → **no bonus (TICKET-486)**.
  - The three surfaces above never reconcile → **three totals (TICKET-490)**.

Deliverable: fill in [`FINDINGS.md`](./FINDINGS.md) — source of truth per value,
root cause per ticket, fix direction (what becomes canonical, what stops being
written, what one-time migration is needed).

### Reproducing Part 2 locally
```bash
cd ASSIGNMENT && docker compose up -d && cd ..   # Postgres on :5433
psql postgresql://postgres:postgres@localhost:5433/assignment
#  \dt  list tables   \d <table>  columns   \df  functions/triggers
```

---

## Conventions for agents working here

- **Verify, don't trust.** Part 1 is verified by `pnpm test`; Part 2 by querying
  the seeded DB. Run them — don't assume a change is correct.
- **Fix logic, not tests.** Hidden suites re-run the Part 1 modules; editing
  assertions to make them pass won't hold up.
- **Keep changes targeted.** These are small, surgical bugs and a focused
  investigation — match the surrounding code style; don't refactor broadly.
- **Don't rewrite git history or backdate commits.** The real timeline is graded;
  an honest messy history is preferred. Ideally one commit/PR per piece of work.
- **Parallel work:** the README suggests running multiple agents (git worktrees /
  Conductor / Superset). Part 1 and Part 2 are independent — split them. **Claim
  a row on the status board above before starting** so two agents don't both edit
  the same file.
- **Before submitting:** run `pnpm logs:capture`, confirm `.claude-logs/` has your
  sessions, commit it, and write `SUMMARY.md` (what's done / how you found the
  Part 2 cause / what you'd do with one more hour).

## Commands

```bash
pnpm install                                   # deps (already installed)
cd ASSIGNMENT && docker compose up -d && cd ..  # Part-2 Postgres on :5433
pnpm test            # Part-1 unit tests — currently 98/98 green
pnpm test:watch      # re-run on change
pnpm typecheck       # tsc --noEmit
pnpm lint            # eslint (incl. no-hardcoded-strings)
pnpm logs:capture    # export AI session transcripts (required for grading)
```
