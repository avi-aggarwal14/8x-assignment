# SUMMARY

## What got done

**Part 1 — bugs: complete (3/3).** All three failing test files pass; the full
suite is green (`pnpm test` → 98/98). Fixes are logic-level, no assertions
touched:
- `lib/modules/phone-verification/rate-limit.ts` — off-by-one (`<=` → `<`): a
  limit of N was admitting N+1.
- `lib/admin/lookup/classify.ts` — `AD_CODE_RE` widened `{4,5}` → `{4,12}` to
  match the module's own documented 4–12-char ad codes.
- `lib/modules/cpm/utils.ts` — CPM divisor `/10000` → `/1000` (CPM is per
  **1,000** views); every payout was 10× too small.
- `tsconfig.json` — `"jsx": "react-jsx"` → `"preserve"` (required for Next.js;
  the mistake was masked from `tsc` by `noEmit` + React 19 auto-runtime types and
  would only surface at `next build`). `pnpm typecheck` clean.

**Part 2 — investigation: complete and verified; demonstration fix written.**
Full write-up in [`FINDINGS.md`](./FINDINGS.md). Reproduced all three tickets
against the live seeded DB (queries + actual output quoted), root-caused each,
and wrote an idempotent migration that fixes them
([`ASSIGNMENT/db/migrations/0001_fix_payment_source_of_truth.sql`](./ASSIGNMENT/db/migrations/0001_fix_payment_source_of_truth.sql)),
verified before/after on the database.

**Supporting docs** ([`ARCHITECTURE.md`](./ARCHITECTURE.md),
[`CLAUDE.md`](./CLAUDE.md)) — a full map of the codebase and an agent status
board, kept in sync with every change.

**What I did *not* do:** I did not change application/production code for Part 2
(the README asks for understanding over a patch, and the trigger bodies are
verbatim from prod). The migration fixes the slice's DB triggers and adds a
ledger projection, but the app-level writers (`update-base`, `reprice-posts`)
and out-of-slice RPCs (`process_post_payment`) would also need to be
consolidated — out of scope for the time, and called out explicitly in FINDINGS.

## Part 2 — how I spotted the cause, and where I got to

Method: reproduce first, then trace each number to the code that produced it.

1. Ran the TICKETS.md snapshot query against the live DB → Maria `$1`/`$0` bonus,
   Teo `$5`/`$0` bonus marked `paid`. Reproduced.
2. Compared the three config tables side by side. Two divergences were visible in
   plain SQL: `managed_creators.base_pay` = `100`/`500` (≠ the campaign's `1000`),
   and the milestone JSON shape `{views, bonus_cents}` (≠ the trigger's expected
   `{min_views, amount_cents}`).
3. Read the triggers in `init.sql` and confirmed the payment path reads
   `managed_creators`, **never** `brand_campaigns`. So:
   - **TICKET-481 ($1):** base pay copied from the stale `managed_creators.base_pay`
     (100¢) instead of the campaign's 1000¢.
   - **TICKET-486 (no bonus):** trigger reads `min_views`/`amount_cents` on
     legacy-shaped rows → both NULL → `NULL <= views` never true → bonus 0. Proved
     it by running the trigger's exact JSONB aggregate (0 rows).
   - **TICKET-490 (three totals):** admin panel reads the frozen snapshot, wallet
     reads the `creator_transactions` ledger, brand report reads `brand_campaigns`
     — three stores, nothing reconciles them. Built a one-query side-by-side
     showing Maria `$1 / $0 / $60` and Teo `$5 / $5 / $60`.
4. Went one level deeper on the **write side**: grepped every writer of the
   `*_cents` columns and found ≥4 paths with *different* base-pay formulas (the
   create trigger uses `base_pay`, `reprice-posts` uses `base_pay/platform_count`,
   `update-base` lets an admin type it, prod's `process_post_payment` RPC writes
   paid directly). The override endpoints themselves are ops papering over wrong
   trigger output — that's the deeper root cause behind "nobody agrees."

Where I got to: complete root cause for all three tickets, a verified fix
(triggers re-sourced from `brand_campaigns`, canonical + key-tolerant milestone
handling, ledger-projected `total_paid_cents`/`payment_status`, one-time
backfill), and an honest scope of what a *production* fix would additionally
require.

## With one more hour

1. **Consolidate the writers.** Extract a single `compute_post_pay(mcp_id)`
   function and route the create trigger, recalc trigger, `update-base`,
   `reprice-posts`, and `process_post_payment` through it — so one formula,
   sourced from `brand_campaigns` + the ledger, produces every number.
2. **Add an explicit per-creator override column** (e.g.
   `managed_creators.base_pay_override_cents`) so legitimate negotiated rates
   survive without `base_pay` being a silently-stale default.
3. **Reconcile the read surfaces** — point the admin panel at the same derived
   values the wallet/ledger use, and add a check (or DB view) that flags any post
   where snapshot ≠ ledger ≠ campaign, to catch drift going forward.
4. **Audit the data migration blast radius** — quantify how many existing posts
   are underpaid (like Teo, marked `paid` for a fraction of what's owed) before
   running the backfill in prod, and decide the auto-credit policy (step 4e in the
   migration, left commented).

## How to verify this work

```bash
# Part 1
pnpm test                      # 98/98 green

# Part 2 — reproduce, then fix, on the local slice
cd ASSIGNMENT && docker compose up -d            # Postgres on :5433, buggy seed
docker exec assignment_db psql -U postgres -d assignment -c "
  SELECT mc.display_name, mcp.total_owed_cents, mcp.bonus_cents, mcp.payment_status
  FROM managed_creator_posts mcp JOIN managed_creators mc ON mc.id=mcp.managed_creator_id;"
#   -> Maria 100/0/unpaid, Teo 500/0/paid   (the bug)
docker exec -i assignment_db psql -U postgres -d assignment \
  < db/migrations/0001_fix_payment_source_of_truth.sql
#   -> Maria 6000/5000/unpaid, Teo 6000/5000/partially_paid   (fixed)
```
