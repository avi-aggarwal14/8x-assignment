# FINDINGS — Part 2

> All claims below were **reproduced against the live seeded database**
> (`docker compose up -d`, Postgres on `localhost:5433`). Queries + their actual
> output are quoted inline so each conclusion is checkable.

## TL;DR

The payment triggers in `ASSIGNMENT/db/init.sql` compute a post's pay from the
**`managed_creators`** row (a stale, per-creator copy), **not** from the brand's
`brand_campaigns` config. The copy has drifted from the campaign in two ways —
**value** (base pay) and **JSON shape** (bonus milestones) — and a third store
(the `creator_transactions` ledger) is updated independently. The result is one
underpaid post, one missing bonus, and three UIs that read three different
numbers.

Reproduction of the admin panel snapshot:

```sql
SELECT mc.display_name, mcp.base_pay_cents, mcp.bonus_cents,
       mcp.total_owed_cents, mcp.total_paid_cents, mcp.payment_status
FROM managed_creator_posts mcp
JOIN managed_creators mc ON mc.id = mcp.managed_creator_id;
```
```
 display_name | base_pay_cents | bonus_cents | total_owed_cents | total_paid_cents | payment_status
 Maria G.     |            100 |           0 |              100 |                0 | unpaid
 Teo R.       |            500 |           0 |              500 |              500 | paid
```
Maria: **$1.00** owed, no bonus. Teo: **$5.00** owed, no bonus, and marked
**`paid`** after receiving $5 — against a real obligation of $60.

---

## 1. Where the money lives

| Value | Real source of truth (should be) | What the system actually uses | Redundant / stale copies |
|---|---|---|---|
| **Base pay per post** | `brand_campaigns.base_pay_per_video_cents` (= `1000` / $10) | `managed_creators.base_pay` (NUMERIC-as-cents), frozen into `managed_creator_posts.base_pay_cents` | `managed_creators.base_pay`, `managed_creator_posts.base_pay_cents`, `jobs.cpm_base_pay` |
| **Bonus milestones** | `brand_campaigns.bonus_milestones` in `{min_views, amount_cents}` shape | `managed_creators.bonus_milestones` / `managed_creator_posts.bonus_milestones` in **legacy** `{views, bonus_cents}` shape | `jobs.bonus_milestones` (empty `[]` here), plus the two legacy-shape copies |
| **Amount owed** | Derived: `base + bonus` from the campaign, against current views | Frozen snapshot `managed_creator_posts.total_owed_cents` (`= calculated_pay_cents + bonus_cents`, capped by `max_pay_cents`) | the snapshot itself — goes stale vs. config and vs. views |
| **Amount actually paid** | `creator_transactions` ledger (per `lib/modules/creator/ledger.ts`: "all balances derived from `creator_transactions` — no cached values") | **Two** independent records: `managed_creator_posts.total_paid_cents` *and* the ledger | they can disagree — Maria has a `total_paid_cents` column but **zero** ledger rows |

The brand config (`base_pay_per_video_cents`, `bonus_milestones`) is the
intended truth, but **nothing in the payment path reads it.** The trigger reads
`managed_creators`:

```sql
SELECT 'brand_campaign' src, base_pay_per_video_cents::text base, bonus_milestones::text bonus
FROM brand_campaigns;
--  brand_campaign | 1000 | [{"min_views": 500000, "amount_cents": 5000}]

SELECT display_name, base_pay::text, cpm_rate, max_pay_cents, bonus_milestones::text
FROM managed_creators;
--  Maria G. | 100 | <null> | <null> | [{"views": 500000, "bonus_cents": 5000}]
--  Teo R.   | 500 | <null> | <null> | [{"views": 500000, "bonus_cents": 5000}]
```

Note the two divergences in plain sight: `100`/`500` ≠ `1000`, and
`{views, bonus_cents}` ≠ `{min_views, amount_cents}`.

---

## 2. Root cause of each ticket

### TICKET-481 — "$1 payout"

`create_managed_creator_post()` (trigger on `posts` INSERT) has no CPM rate, so
it takes the flat-pay branch:

```sql
IF v_mc.cpm_rate IS NOT NULL AND v_mc.cpm_rate > 0 THEN ...
ELSE
    v_calculated_pay := v_mc.base_pay_cents;   -- = COALESCE(mc.base_pay,0)::INTEGER
END IF;
```

Maria's `managed_creators.base_pay = 100`, so `base_pay_cents = 100` = **$1.00**.
The campaign's `base_pay_per_video_cents = 1000` ($10) is **never consulted**.
`managed_creators.base_pay` is a redundant per-creator copy that has drifted
from (or was never reconciled to) the campaign — it's $1 for Maria, $5 for Teo,
and neither equals the $10 the brand configured. **Root cause: base pay is
sourced from a stale `managed_creators` copy instead of `brand_campaigns`.**

### TICKET-486 — "missing 500k bonus"

Both creators are past the 500k milestone:

```sql
SELECT mc.display_name, p.latest_views FROM posts p
JOIN managed_creators mc ON mc.tiktok_account_id = p.tiktok_account_id;
--  Maria G. | 600000     Teo R. | 700000
```

But the trigger extracts the milestone with the **wrong keys**:

```sql
SELECT COALESCE(MAX((elem->>'amount_cents')::INTEGER), 0)
FROM jsonb_array_elements(v_mc.bonus_milestones) elem
WHERE (elem->>'min_views')::INTEGER <= v_views;
```

The stored milestone is the **legacy shape** `{"views":500000,"bonus_cents":5000}`,
so `elem->>'min_views'` and `elem->>'amount_cents'` both read **NULL**:

```sql
SELECT (elem->>'amount_cents')::int AS amount_read,
       (elem->>'min_views')::int    AS min_views_read,
       elem->>'bonus_cents', elem->>'views'
FROM managed_creator_posts mcp
CROSS JOIN LATERAL jsonb_array_elements(mcp.bonus_milestones) elem;
--  amount_read | min_views_read | bonus_cents | views
--    <null>    |    <null>      |    5000     | 500000
```

The filter becomes `NULL <= 600000` → **NULL (never true)** → `MAX()` over zero
rows → `COALESCE(..., 0)` → **bonus = 0**. The correct `{min_views, amount_cents}`
shape exists *only* on `brand_campaigns`, which the trigger doesn't read. **Root
cause: the trigger reads the campaign's milestone schema against legacy-shaped
data, so `min_views` is NULL and the milestone never qualifies.**

### TICKET-490 — "the numbers don't match" (admin panel vs wallet vs brand spend)

Three surfaces each read a **different store**, and nothing reconciles them:

```sql
-- per creator: admin snapshot vs ledger vs brand-intended
 display_name | latest_views | admin_owed | admin_paid | admin_status | wallet_earned | brand_intended
 Maria G.     |       600000 |        100 |          0 | unpaid       |             0 |           6000
 Teo R.       |       700000 |        500 |        500 | paid         |           500 |           6000
```

Confirmed in the app code (exact lines, so this is checkable, not asserted):

- **(1) Admin payouts panel** → the **frozen snapshot** `managed_creator_posts`.
  `app/api/admin/creator-post-payments/route.ts` reads it two ways: grouped mode
  calls the `get_grouped_post_payments` RPC over that table
  ([route.ts:166](app/api/admin/creator-post-payments/route.ts#L166), mapped to
  `total_owed_cents`/`total_paid_cents` at
  [route.ts:193-198](app/api/admin/creator-post-payments/route.ts#L193-L198)),
  and flat mode selects the snapshot columns directly from
  `managed_creator_posts` ([route.ts:271](app/api/admin/creator-post-payments/route.ts#L271),
  fields at [route.ts:216-256](app/api/admin/creator-post-payments/route.ts#L216-L256)).
  → Maria $1, Teo $5 (wrong base + missing bonus baked in).
- **(2) Creator wallet** → the **`creator_transactions` ledger**, never the
  snapshot. `getWalletDashboard` derives its totals from
  `getCreatorBalance(creator.id)` ([wallet.ts:264](lib/services/wallet.ts#L264),
  surfaced as `total_earned_cents` at [wallet.ts:287](lib/services/wallet.ts#L287)),
  which runs the `get_creator_balance` RPC
  ([ledger.ts:54](lib/modules/creator/ledger.ts#L54)); the module is explicit that
  *"All balances are derived from creator_transactions - no cached values"*
  ([ledger.ts:5](lib/modules/creator/ledger.ts#L5)). → Maria **$0** (no ledger
  rows), Teo **$5** (one manually inserted `earning` of 500).
- **(3) Brand campaign view** → reads **both, inconsistently with itself**.
  `app/api/admin/brand-campaigns/[campaignId]/detail/route.ts` surfaces the
  *campaign config* rate `base_pay_per_video_cents` + `bonus_milestones`
  ([detail/route.ts:115,120](app/api/admin/brand-campaigns/[campaignId]/detail/route.ts#L115))
  — i.e. "$10/video + $50 bonus = **$60**" — but computes its spend **stats by
  summing the snapshot** `total_owed_cents`/`total_paid_cents`
  ([detail/route.ts:148-184](app/api/admin/brand-campaigns/[campaignId]/detail/route.ts#L148-L184)).
  So the brand sees a configured $60 rate sitting next to snapshot-derived totals
  of $1/$5 — the config value it set is shown but **never feeds any payable
  number**.

So for Maria the same post is simultaneously **$1 / $0 / $60**, and for Teo
**$5 / $5 / $60**. **Root cause: three denormalized stores (frozen snapshot,
ledger, campaign config) are written and read independently with no
reconciliation, so they drift.** Worse, Teo's `total_paid_cents (500) >=
total_owed_cents (500)` flips `payment_status` to `paid`, so a creator owed $60
is reported as fully settled for $5.

### Why it never self-heals

The recalc trigger `recalculate_managed_creator_post_payment()` (on
`post_engagement_metrics` INSERT) recomputes from the **already-frozen copies on
`managed_creator_posts`** (`v_mcp.base_pay_cents`, `v_mcp.bonus_milestones`),
**not** from live config. The seed inserts a second 700k metric for Teo, which
re-runs this trigger — and it still produces $5 / $0 bonus, because it's reading
the same stale snapshot. New view data can therefore never pull the numbers back
toward what the brand configured.

### The deeper root cause: many writers, contested `base_pay` semantics

Tracing the app code (`grep` for the `*_cents` columns) shows the snapshot is
written by **at least four independent code paths, each with its own formula** —
which is the *write-side* of the same "nobody agrees" problem:

| Writer | How it derives base pay | Result for Maria (`base_pay=100`) |
|---|---|---|
| `create_managed_creator_post()` trigger | `managed_creators.base_pay` as-is | **$1.00** |
| `app/.../reprice-posts/route.ts` | `base_pay / platform_count` (`100/2`) | **$0.50** |
| `app/.../update-base/route.ts` | whatever an admin types | arbitrary |
| `brand_campaigns` (the real truth) | `base_pay_per_video_cents` | **$10.00** |

So `managed_creators.base_pay` has **three contradictory interpretations** in
live code (per-post cents / total-to-split-across-platforms / ignored), none of
which equals the campaign's $10. Likewise none of the app writers fixes the
bonus: `reprice-posts` copies `managed_creators.bonus_milestones` (still the
legacy `{views, bonus_cents}` shape) and preserves the existing `bonus_cents`
(0); `update-base` requires an admin to type the bonus by hand. The production
payout path is yet another writer — the `process_post_payment` RPC (not in this
slice) — which writes `total_paid_cents` directly rather than deriving it from
the ledger. **The existence of `update-base` / `reprice-posts` is itself the
tell: ops built manual-override endpoints to paper over numbers the triggers got
wrong.** A complete fix must route *every* writer through one canonical pay
function sourced from `brand_campaigns` + the ledger — not just fix the two
triggers.

### Blast radius: a fleet-wide money bug, not two rows

Nothing about this defect is specific to Maria and Teo — they just make it
visible. **Every managed-creator post on the flat-pay path is exposed**, in three
compounding ways:

- **Underpayment (systemic).** Any post whose snapshot `base_pay_cents` came from
  a drifted `managed_creators.base_pay` is underpaid, and the recalc trigger can
  never heal it (it recomputes from the *frozen wrong value*). Both seeded
  creators are underpaid 10–20× ($1/$5 vs the configured $10).
- **Missing bonuses (systemic).** Any creator whose milestones are stored in the
  legacy `{views, bonus_cents}` shape gets **$0 bonus at every view count** —
  plausibly the entire pre-schema-change population, not a one-off.
- **False `paid` status (most dangerous).** Because owed is computed too low,
  `total_paid_cents >= total_owed_cents` flips a post to `paid` after a *partial*
  payment (Teo: `paid` for $5 of $60). That hides the underpayment from ops **and**
  suppresses further payout — so the error compounds and silently closes the
  ticket. This is the difference between "a number is wrong" and "a creator is
  underpaid and told they're settled."

Quantify the exposure with one query before any backfill (this is what sizes the
financial blast radius and drives the auto-credit decision in migration step 4e):

```sql
SELECT
  count(*)                                                                  AS total_posts,
  count(*) FILTER (WHERE mcp.base_pay_cents <> bc.base_pay_per_video_cents) AS wrong_base_pay,
  count(*) FILTER (WHERE mcp.bonus_milestones::text LIKE '%bonus_cents%')   AS legacy_milestone_shape,
  count(*) FILTER (WHERE mcp.payment_status = 'paid'
                   AND mcp.total_owed_cents < bc.base_pay_per_video_cents)  AS falsely_marked_paid
FROM managed_creator_posts mcp
JOIN managed_creators mc ON mc.id = mcp.managed_creator_id
JOIN brand_campaigns  bc ON bc.job_id = mc.job_id;
--  total_posts | wrong_base_pay | legacy_milestone_shape | falsely_marked_paid
--       2       |       2        |          2             |         1
```

On the seed that's **100% of posts underpaid, 100% missing bonus, and one already
falsely `paid`**. In production the same query counts the real affected
population — that number (creators owed back-pay, brand spend under-reported, and
who's been wrongly told they're settled), **not** the two demo rows, is what
makes this a P0 financial-correctness bug rather than a cosmetic display glitch.

---

## 3. How you'd fix it

**Single source of truth going forward**
- **Base pay** and **bonus milestones** should be read live from
  `brand_campaigns` (`base_pay_per_video_cents`, `bonus_milestones` in the
  `{min_views, amount_cents}` shape) at compute time — joined via
  `managed_creators.job_id → jobs.id → brand_campaigns.job_id`. Treat
  `managed_creators.base_pay` / `.bonus_milestones` as per-creator **overrides
  only** (explicit, opt-in), not the default source.
- **Money paid** should be the **`creator_transactions` ledger** exclusively, as
  `lib/modules/creator/ledger.ts` already declares. `managed_creator_posts`
  should *derive* `total_paid_cents`/`payment_status` from the ledger (e.g. a
  view or a ledger-triggered recompute), never be written independently.

**What stops being written / read**
- Stop having the payment path read `managed_creators.base_pay` and the
  legacy-shaped `bonus_milestones` as the source. Normalize all milestone JSON
  to one shape (`{min_views, amount_cents}`) — pick one schema and migrate.
- Stop writing `total_paid_cents` by hand (as the seed does). It must be a
  projection of the ledger.

**What to snapshot vs. read live**
- It's legitimate to **freeze** the *agreed rate* at the moment of acceptance
  (so a later campaign-rate change doesn't silently re-price old posts) — but if
  you snapshot, snapshot the **correct** values from `brand_campaigns`, and
  treat `total_owed_cents` as derived (rate × current views + qualifying bonus),
  recomputed on each metrics update. **`owed` should be live; the contracted
  rate may be snapshotted.** What you must *not* do is snapshot a wrong value and
  then recompute *from that snapshot* forever (today's bug).

**One-time data cleanup (migration)**
1. **Re-derive base pay** for affected `managed_creator_posts` from the owning
   `brand_campaigns.base_pay_per_video_cents` (Maria/Teo → 1000¢).
2. **Normalize bonus milestone JSON** from `{views, bonus_cents}` →
   `{min_views, amount_cents}` everywhere it's stored
   (`managed_creators`, `managed_creator_posts`), or change the trigger to read
   both keys during a transition.
3. **Recompute** `calculated_pay_cents`, `bonus_cents`, `total_owed_cents` for
   all posts using corrected inputs + current views (both creators → 6000¢).
4. **Backfill the ledger**: insert the missing `creator_transactions` earning
   rows so wallet = owed, then recompute `total_paid_cents`/`payment_status`
   from the ledger. Re-open Teo's status (paid $5 of $60 ≠ `paid`).

**Open questions I'd resolve before shipping a production fix** (things the slice
can't answer on its own — I'd confirm with whoever owns this data/code):

- **Is `managed_creators.base_pay` ever a *legitimate* per-creator rate, or pure
  drift?** That decides the migration: if real negotiated overrides exist, it
  becomes an explicit `base_pay_override_cents` the campaign falls back to; if
  it's only a stale mirror, it gets dropped. (Maria 100 / Teo 500 vs campaign
  1000 looks like drift / a 10× units slip, but I wouldn't delete a money column
  on a guess.)
- **Can one `job` have more than one `brand_campaign`?** The fix joins
  `brand_campaigns` via `job_id` and the seed is 1:1, but campaigns carry
  `platforms`/`country` — if a job fans out to several, "which campaign's rate"
  needs a real selection rule, not `LIMIT 1`.
- **Do the out-of-slice writers get repointed too?** `process_post_payment`,
  `record_earning_atomic`, and `get_grouped_post_payments` live in prod, not this
  slice — the fix only holds if they route through the same canonical pay
  function + ledger. I'd read those bodies before calling it done.
- **CPM path parity.** These creators are flat-pay (`cpm_rate` NULL). I'd verify
  the separate CPM submissions path (`cpm_submissions`, `jobs.cpm_base_pay` — yet
  another unused copy) has the same source-of-truth discipline.
- **Auto-credit policy.** Whether to back-pay each creator's shortfall (migration
  step 4e, left commented) is a finance/legal call, not an engineering one.

---

## 4. Anything you actually changed

- **No application/production code changed.** The investigation (above) is the
  primary deliverable, per the README.
- I **started and seeded the local DB** and ran read-only diagnostic queries to
  verify every claim before changing anything.
- As a concrete demonstration of the fix direction in §3, I wrote a migration:
  **`ASSIGNMENT/db/migrations/0001_fix_payment_source_of_truth.sql`** (placed in
  a subdirectory so the Postgres entrypoint does *not* auto-run it on a fresh
  boot). It:
  1. Sources `base_pay_cents` + `bonus_milestones` from `brand_campaigns`
     (joined via `managed_creators.job_id`), with `managed_creators` as an
     explicit fallback only.
  2. Normalizes milestone JSON to canonical `{min_views, amount_cents}` and
     reads it **key-tolerantly** (accepts the legacy shape during transition).
  3. Projects `total_paid_cents` / `payment_status` from `creator_transactions`
     via a new `AFTER INSERT/UPDATE/DELETE` trigger (`trigger_sync_post_paid`).
  4. Backfills + recomputes every existing post.

  Apply with:
  ```bash
  docker exec -i assignment_db psql -U postgres -d assignment \
    < ASSIGNMENT/db/migrations/0001_fix_payment_source_of_truth.sql
  ```

- **Verified before/after on the live DB:**

  | | base_pay_cents | bonus_cents | total_owed_cents | total_paid_cents | status |
  |---|---|---|---|---|---|
  | Maria (before) | 100 | 0 | 100 | 0 | unpaid |
  | Maria (after)  | **1000** | **5000** | **6000** | 0 | unpaid |
  | Teo (before)   | 500 | 0 | 500 | 500 | **paid** |
  | Teo (after)    | **1000** | **5000** | **6000** | 500 | **partially_paid** |

  Forward checks also pass: a new `post_engagement_metrics` row recomputes
  `total_owed` to $60 via the corrected recalc trigger, and inserting a ledger
  `earning` auto-updates `total_paid_cents` + `payment_status` (no hand-written
  column). The `4e` step (auto-crediting missing wallet earnings) is left
  **commented** — moving money is a business decision, not a mechanical fix.

  > Note: these forward checks mutated the throwaway container (added one metric
  > + one transaction for Maria). Re-run `docker compose down -v && docker
  > compose up -d` from `ASSIGNMENT/` for a pristine seed. Verified
  > **idempotent** (applying twice yields the same result).

- **Scope / honesty caveat:** the migration fixes the two triggers in this slice
  and adds the ledger projection, but it does **not** by itself fully fix
  production. The app-level writers (`update-base`, `reprice-posts`) and the
  out-of-slice RPCs (`process_post_payment`, `record_earning_atomic`,
  `get_grouped_post_payments`) still write/derive these numbers with their own
  formulas (see §2 "many writers"). A real fix consolidates all of them onto one
  canonical pay function sourced from `brand_campaigns` + the ledger.
