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

- **(1) Admin payouts panel** (`app/api/admin/creator-post-payments/route.ts`)
  reads the **frozen snapshot** `managed_creator_posts.total_owed_cents` →
  Maria $1, Teo $5. Wrong base + missing bonus baked in.
- **(2) Creator wallet** (`lib/services/wallet.ts` → `lib/modules/creator/ledger.ts`)
  reads the **`creator_transactions` ledger** → Maria **$0** (no ledger rows at
  all), Teo **$5** (one manually inserted `earning` of 500).
- **(3) Brand spend report** reads the **`brand_campaigns` config** → each
  creator should be $10 base + $50 bonus = **$60 (6000¢)**.

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

---

## 4. Anything you actually changed

- **No production code changed.** This is an investigation; the deliverable is
  the analysis above. (Per the README, Part 2 prioritizes correct understanding
  over a patch, and the trigger bodies are "verbatim from prod migrations.")
- I did **start and seed the local DB** (`ASSIGNMENT/docker compose up -d`) and
  ran read-only diagnostic queries to verify every claim. No rows were mutated.
- Suggested next change (not yet applied), smallest-first:
  1. In both trigger functions, source `base_pay_cents` and `bonus_milestones`
     from `brand_campaigns` (joined via `managed_creators.job_id`), falling back
     to per-creator overrides only when explicitly set.
  2. Normalize milestone JSON to `{min_views, amount_cents}` (migration + a
     transitional key-tolerant read).
  3. Make `total_paid_cents` / `payment_status` a projection of
     `creator_transactions`, and backfill the missing ledger rows.
