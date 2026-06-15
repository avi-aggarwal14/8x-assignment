# Architecture

> A map of this repository — what it is, how it's laid out, where each concern
> lives, and where the dangerous/messy parts are. Written for someone landing
> in this codebase cold.
>
> This repo is a **slice of a production codebase** (the "8x" creator-payments
> platform) packaged as a timed engineering assignment. It is meant to be
> **read and navigated**, not booted in full — the live web server depends on
> Supabase + Stripe + other services that aren't provided. Only two things
> actually run locally: the **unit tests** (Part 1) and a **local Postgres
> container** seeded from `ASSIGNMENT/db` (Part 2).

---

## 1. What the product is

8x is a marketplace connecting **brands** (who run video marketing campaigns)
with **creators** (who post videos on TikTok / Instagram / YouTube and get
paid). The platform has three principal actors and an internal ops team:

- **Creators** — apply to jobs, post videos, accrue earnings, withdraw to a
  Stripe Connect account. Two earning models coexist:
  - **Flat / managed** pay: a fixed `base_pay` per video plus optional view
    **milestone bonuses** (e.g. "+$50 at 500k views"). Managed by ops.
  - **CPM** pay: pay-per-1,000-views, with a base pay and a per-video cap.
- **Brands** — configure campaigns (`jobs` / `brand_campaigns`), set pay rates
  and bonus milestones, see spend reports.
- **Admins / ops** — an internal back-office: review videos, manage "managed
  creators", run payouts, inspect social accounts, look up entities, warm up
  burner accounts.
- **Mobile app** — a separate React Native client that talks to a dedicated
  `/api/mobile/*` surface (JWT-authenticated) sharing the same service layer.

The hard, central domain — and the focus of the assignment — is **how a single
post's pay is computed, frozen, paid, and read back** across several tables and
several UIs that don't agree with each other.

---

## 2. Tech stack

| Concern | Choice |
|---|---|
| Framework | **Next.js 16** (App Router, React 19, Turbopack), TypeScript strict |
| Package manager | **pnpm 10** (workspace; see `pnpm-workspace.yaml`) |
| Styling | Tailwind CSS v4, `tailwind-merge`, `class-variance-authority`, shadcn/ui (Radix primitives in `components/ui`) |
| Data / backend | **Supabase** (Postgres + Auth + Storage + RLS + RPC functions) via `@supabase/supabase-js` and `@supabase/ssr` |
| Payments | **Stripe** (Connect for creator payouts, subscriptions, checkout) — multi-region router |
| i18n | **next-intl** — 13 locales, locale-prefixed routes, per-domain locale mapping |
| Data grids | **AG Grid** (`ag-grid-react` v35) for admin tables; `@tanstack/react-table` elsewhere |
| Forms | `react-hook-form` + `zod` resolvers |
| Rich text | **TipTap** (editor), `react-markdown` / `remark` / `rehype` (rendering), `turndown` (HTML→MD) |
| Email / SMS / push | `nodemailer` + `resend` (email), `twilio` (SMS), Expo push tokens; **Slack** Web API for ops alerts |
| Storage | Supabase Storage **and** AWS S3 / Cloudflare R2 (`@aws-sdk/client-s3`, `tus-js-client` for resumable uploads) |
| AI | `@anthropic-ai/sdk`, `@google/genai`, `groq-sdk` — used in `lib/video` (video analysis / replication review) |
| Observability | **Sentry** (`@sentry/nextjs`) + **PostHog** (client + node) + Vercel Analytics |
| Validation / security | `zod`, `isomorphic-dompurify`, `jose` (JWT), `bcryptjs`, origin validation |
| PDFs | `@react-pdf/renderer` (creator contracts) |
| Testing | **Vitest** + Testing Library + jsdom (unit); **Playwright** (e2e, config excluded from this slice) |
| Lint/format | ESLint 9 (flat config) + `eslint-config-next` + a custom **no-hardcoded-strings** rule (i18n enforcement); Prettier |

Path alias: `@/*` → repo root (`tsconfig.json`).

---

## 3. Top-level layout

```
.
├── ASSIGNMENT/            # Part 2: self-contained Postgres slice (the payments puzzle)
│   ├── db/init.sql        #   tables + payment TRIGGERS/FUNCTIONS (verbatim from prod migrations)
│   ├── db/seed.sql        #   seed rows that DRIVE the triggers (no payment columns written by hand)
│   ├── db/migrations/     #   0001_fix_payment_source_of_truth.sql — demonstration fix (NOT auto-loaded; apply manually). See §8.
│   └── docker-compose.yml #   Postgres on localhost:5433, auto-loads init.sql + seed.sql (NOT db/migrations/)
│
├── app/                   # Next.js App Router — pages + the entire API surface
│   ├── [locale]/          #   locale-prefixed UI, split into (admin) and (dashboard) route groups
│   └── api/               #   REST endpoints: admin, creator, jobs, applications, webhooks, hooks
│
├── components/            # React components (96 files)
│   ├── ui/                #   shadcn/Radix primitives (button, dialog, table, …)
│   ├── Admin/             #   the back-office: AG Grid column defs, dialogs, detail panels
│   ├── Brand/ Cpm/ Dashboard/ Portal/ shared/   # feature areas
│
├── lib/                   # ALL business logic (163 files) — the heart of the codebase
│   ├── modules/           #   domain modules (cpm, creator, managed-creators, auth, admin, …)
│   ├── services/          #   shared web+mobile service layer (wallet, jobs, applications, …)
│   ├── payments/          #   Stripe integration (Connect, webhooks, region router)
│   ├── db/ supabase/      #   Supabase client factories + typed queries
│   ├── api/               #   route wrappers (validatedRouteWithUser, etc.)
│   ├── mobile/            #   mobile JWT auth + handler functions for /api/mobile/*
│   ├── notifications/ messaging/   # Slack + email + push + in-app notify fan-out
│   ├── analytics/ storage/ video/ utils/ …
│
├── hooks/ i18n/ types/    # React hooks, locale config, generated Supabase types
├── scripts/               # capture-logs.mjs (exports AI session transcripts for grading)
├── tests/                 # Vitest setup
│
├── README.md              # assignment instructions (start here)
├── TICKETS.md             # Part 2: three support tickets (all one root cause)
├── FINDINGS.md            # Part 2 deliverable (fill in)
└── config: next.config.ts, tsconfig.json, eslint.config.js, vitest.config.ts,
            tailwind.config.js, components.json, i18n.ts, package.json
```

---

## 4. Application & routing structure (`app/`)

Next.js **App Router** with everything under a `[locale]` dynamic segment
(next-intl, `localePrefix: 'always'` — every URL carries a locale).

### UI route groups (`app/[locale]/`)
- **`(admin)/admin/…`** — the internal ops console:
  - `campaigns/` — brand campaign management
  - `creator-post-payments/` — **the admin payouts panel** (the "frozen
    snapshot" view in TICKET-490). Reads `managed_creator_posts.*_cents`
    columns. Dialogs: change pricing, mark-paid-off-platform, min-views check,
    pay-selected, verify-posts.
  - `lookup/` — admin entity lookup (paste a URL/ID/ad-code → resolve it).
    Backed by `lib/admin/lookup/classify.ts` (**Part-1 bug #2 — fixed**).
- **`(dashboard)/dashboard/…`** — the creator/brand-facing app:
  - `find/` — job feed + apply modal
  - `[brandSlug]/contract/` — creator contract page (renders a PDF)
  - `hooks/` — co-located route hooks (`useApplyJob`)

> Note: this slice ships only a handful of pages (`page.tsx`) and **no root
> layouts** — it's a curated subset. The full app has far more.

### API surface (`app/api/`) — ~45 route handlers
All REST, grouped by audience:

- **`api/admin/*`** — admin-only. Brand campaigns, brands, creators, managed
  creators (posts, reprice, cascade-pay, warmup), creator-post-payments
  (list / pay / update-base / verify), payouts, video-reviews, country-pricing,
  inspector actions. These mostly use the **service-role client** + a manual
  `account_type === 'admin'` check.
- **`api/creator/*`, `api/creators/*`** — creator-facing: posts, report-post,
  workspace, wallet/paid-posts.
- **`api/jobs/*`, `api/applications/*`, `api/cpm/*`, `api/managed-creators/*`**
  — public/creator job + application flows.
- **`api/webhooks/new-managed-post`** — Supabase DB webhook → Slack review
  ping. Protected by **cron secret** (`lib/cron/auth.ts`, timing-safe compare).
- **`api/hooks/*`** — internal processing hooks: `process-video`,
  `disclosure-check`.

> The **mobile** surface (`/api/mobile/*`) referenced throughout `lib/mobile/`
> and `lib/services/` is **not present in this slice** (the handler functions in
> `lib/mobile/handlers.ts` exist; the catch-all route does not). Treat
> `lib/services/*` as the shared contract that both web routes and the mobile
> catch-all call into.

### Route handler conventions
Two patterns coexist:
1. **Wrapped** (preferred, `lib/api/route-helpers.ts`):
   `validatedRouteWithUser(schema, handler, {name})` / `routeWithUser` /
   `fileUploadRouteWithUser`. These centralize: origin validation → auth
   (`getUser()`) → JSON parse → Zod validate → call handler → normalize result
   to a `Response` → Sentry/PostHog error capture. Business failures are
   returned as `{ error, statusCode? }` and mapped to HTTP status (default 422).
2. **Hand-rolled** (e.g. `api/admin/creator-post-payments/route.ts`): manual
   `getUser()`, manual admin check, manual `try/catch` + `captureDbError`. More
   verbose; common in the admin area.

---

## 5. The `lib/` business-logic layer

This is where ~all real logic lives. Organizing principle is loosely
**domain modules** (`lib/modules/*`) + a cross-cutting **service layer**
(`lib/services/*`) + infrastructure (db, payments, notifications, analytics,
storage).

### `lib/modules/*` — domain modules
Each module is a folder with some mix of `types.ts`, `queries.ts`,
`actions.ts`, `hooks.ts`, `constants.ts`, `utils.ts`:

- **`cpm/`** — pay-per-view earning model. `utils.ts` has the earnings math
  (**Part-1 bug #3 — fixed**), `payouts.ts` processes a submission payout via an atomic
  Postgres RPC then a Stripe transfer, plus `budget-actions`, `post-fetch`,
  `url-parser`, `error-codes`.
- **`creator/`** — `ledger.ts` is the **single source of truth for creator
  money** (see §7). Plus `queries`, `services`, `post-filters`.
- **`managed-creators/`** — ops-managed creators: linking to social accounts
  (`auto-link`, `join`), status transitions, repricing, drop side-effects,
  notifications.
- **`phone-verification/`** — `rate-limit.ts` in-memory sliding-window limiter
  (**Part-1 bug #1 — fixed**), used for SMS verification and (reused) the mobile sync
  button.
- **`admin/`** — `roles`, `audit-log`, `api-middleware`, and the social-account
  **`inspector/`** subsystem (actions/queries/types).
- **`portal/`** — brand "portal" config + creator contract template/lifecycle.
- **`warmup/`** — burner-account warmup windows, screenshot verification.
- Others: `jobs/`, `applications/`, `auth/`, `billing/`, `context/`
  (brand/creator request context + validators), `team/`, `onboarding/`,
  `cache-constants`.

### `lib/services/*` — shared web + mobile services
Thin, framework-agnostic functions taking a `ServiceContext` (`{ user,
supabase, elevatedSupabase? }`, see `_types.ts`). One implementation, two
callers (Next.js routes and the mobile catch-all). Includes `wallet.ts`
(wallet dashboard, Stripe payout, Connect onboarding, transfer pending
earnings), `jobs.ts`, `applications.ts`, `creator-profile.ts`,
`handle-validation.ts`. Errors thrown as `ServiceError(status, message,
details)`.

### `lib/admin/lookup` — admin entity classifier
`classify.ts` is a **pure** discriminated-union classifier: raw input →
`{kind: 'post-id' | 'post-url' | 'ad-code' | 'username' | …}`. `queries.ts`
resolves each kind to a canonical URL. Order of checks matters (UUID → URL →
@username → ad-code → bare username). **Part-1 bug #2 lived here — fixed.**

---

## 6. Data access & auth

### Three Supabase clients (`lib/db/supabase.ts`) — choosing the wrong one is a security bug
| Factory | Key | RLS | Use for |
|---|---|---|---|
| `createServerSupabaseClient()` | publishable | enforced | unauthenticated public reads |
| `createAuthenticatedSupabaseClient()` (cached) | cookie session | enforced | **default** for authenticated server code — throws if no session; 263+ files assume this |
| `createServiceRoleClient()` | secret | **bypassed** | admin routes, webhooks, mobile handlers — **every query must be manually scoped to the user**, since RLS is off |

`lib/supabase/{server,client}.ts` wrap `@supabase/ssr` for cookie-based
sessions in Server Components / Route Handlers and the browser.

### Auth (`lib/modules/auth/queries.ts`)
`getUser()` (React-`cache`d, once per request): reads the Supabase Auth session
→ looks up the internal `users` row by email (RLS-enforced) → falls back to
`requesting_user_id()` RPC and syncs a changed email. User creation happens in a
DB trigger on `auth.users` insert, not here.

The **mobile** path authenticates differently: `lib/mobile/auth.ts`
(`getMobileUser`) validates a JWT and then uses the service-role client — so the
handlers in `lib/mobile/handlers.ts` carry the manual-scoping burden (note the
repeated `.eq('user_id', user.id)` ownership guards).

### Typed schema
`types/supabase.ts` (generated) is the source of truth for table/column/enum
types, imported as `Database`. `lib/db/types.ts` exports app-level types like
`User`.

---

## 7. The payments domain (read this carefully)

Money is the most tangled part of the system, and it's tangled because the
**same value is represented in several places that can drift apart.** There are
two parallel pay systems and three "views of the truth."

### Two pay systems
1. **CPM submissions** (`cpm_submissions` table, `lib/modules/cpm/*`) — modern.
   Earnings computed from `views_approved`, paid incrementally via the
   `process_cpm_payout` atomic RPC, then a Stripe transfer.
2. **Managed creator posts** (`managed_creator_posts`, the `ASSIGNMENT/db`
   slice) — the legacy/flat model. Pay is **frozen by database triggers** when a
   post lands and **recalculated by triggers** when new view metrics arrive.

### The ledger is the *intended* single source of truth for creator money
`lib/modules/creator/ledger.ts` insists **all balances are derived from the
`creator_transactions` ledger — no cached values.** It exposes
`recordEarning` / `recordWithdrawal` (atomic RPCs with advisory locks),
`getCreatorBalance` (via `get_creator_balance` RPC),
`getPendingStripeTransactions`, `markTransactionsTransferred`. Withdrawals are
stored negative; balance = sum of transactions.

### Three disagreeing "totals" (the root of TICKET-490)
The same creator's pay is read back through **three different surfaces that
read different columns/tables**:
1. **Admin payouts panel** → `app/api/admin/creator-post-payments/route.ts`
   reads `managed_creator_posts.{base_pay_cents, bonus_cents, total_owed_cents,
   total_paid_cents}` — the **frozen trigger snapshot**.
2. **Creator wallet** → `lib/services/wallet.ts` →
   `lib/modules/creator/ledger.ts` reads the **`creator_transactions` ledger**.
3. **Brand spend report** → derived from **`brand_campaigns` config**
   (`base_pay_per_video_cents`, `bonus_milestones`) — what the brand *intended*
   to pay.

These three can produce three different numbers because nothing reconciles the
frozen snapshot, the ledger, and the campaign config. That gap is the
investigation.

### Stripe integration (`lib/payments/*`)
`stripe.ts` (EU default), `stripe-client-us.ts`, **`stripe-router.ts`**
(`getStripeForRegion` — multi-region), `stripe-connect.ts` (`transferToCreator`,
`getAccountStatus`), `stripe-checkout`, `stripe-customer`,
`stripe-subscriptions`, `stripe-webhooks`. Creators withdraw via Connect;
transfers are always made in USD and Stripe converts to the bank currency.
**"Paid" semantics are a database IOU** — the ledger records the earning/payout
even if the Stripe leg is skipped or fails (see the many partial-success
branches in `cpm/payouts.ts`).

---

## 8. Part 2: the `ASSIGNMENT/` database slice

A self-contained, runnable Postgres slice (`docker compose up -d` →
`localhost:5433`, db `assignment`). The table *shapes* are trimmed to the
payment path; the **trigger function bodies are copied verbatim from production
migrations**, so the behaviour is authentic.

### Tables (`init.sql`)
`jobs`, `brand_campaigns`, `managed_creators`, `posts`,
`post_engagement_metrics`, `managed_creator_posts`, `creator_transactions`.

Pay for one post is spread across `jobs` + `managed_creators` +
`brand_campaigns` + `managed_creator_posts` + the `creator_transactions` ledger
— which is exactly why "where the money lives" is non-trivial.

### The two triggers that compute pay
- `create_managed_creator_post()` — **AFTER INSERT ON posts**. Looks up the
  matching active `managed_creators` row by social-account id, computes
  `calculated_pay` (CPM `rate*views/1000`, else `base_pay`), `bonus` (max
  milestone whose `min_views <= views`), caps at `max_pay_cents`, and **freezes
  a snapshot** into `managed_creator_posts`.
- `recalculate_managed_creator_post_payment()` — **AFTER INSERT ON
  post_engagement_metrics**. Recomputes the same numbers from the **frozen
  copies on `managed_creator_posts`** (not from the live `managed_creators` /
  `brand_campaigns` config) and updates `total_owed_cents` + `payment_status`.

### Where the bugs come from (the seed deliberately plants the mismatch)
`seed.sql` is the key: it sets up **three independent schema/shape mismatches**
between what the brand configured and what the triggers read:

1. **Cents vs dollars / `base_pay` semantics.** The brand campaign says
   `base_pay_per_video_cents = 1000` ($10). But `managed_creators.base_pay` is a
   `NUMERIC` "that stores cents" set to `100` for Maria — and the trigger does
   `COALESCE(mc.base_pay,0)::INTEGER` straight into `base_pay_cents`. $10 vs
   100¢ → **the "$1 payout" (TICKET-481).**
2. **Bonus milestone shape drift.** `brand_campaigns.bonus_milestones` uses the
   **correct** `{min_views, amount_cents}` shape. But `managed_creators` (and
   the frozen `managed_creator_posts`) carry the **legacy** `{views,
   bonus_cents}` shape. The trigger reads `elem->>'amount_cents'` and
   `elem->>'min_views'` — both **NULL** against legacy rows → bonus computes as
   **$0 (TICKET-486).**
3. **Three sources never reconciled.** The admin panel reads the frozen
   `managed_creator_posts` snapshot, the wallet reads `creator_transactions`
   (Teo has a single `500`-cent ledger entry + `total_paid_cents = 500`), and
   the brand report reads `brand_campaigns` config — **three different totals
   (TICKET-490).**

### The deeper root cause: many writers, contested `base_pay` (write side)

Auditing the app code (`grep` for the `*_cents` columns) shows the snapshot is
written by **≥4 independent code paths, each with its own base-pay formula** —
the write-side of the same "nobody agrees" problem:

| Writer | Base-pay formula | Maria (`base_pay=100`) |
|---|---|---|
| `create_managed_creator_post()` trigger | `managed_creators.base_pay` as-is | $1.00 |
| `app/api/admin/managed-creators/[id]/reprice-posts/route.ts` | `base_pay / platform_count` (`100/2`) | $0.50 |
| `app/api/admin/creator-post-payments/update-base/route.ts` | whatever an admin types | arbitrary |
| `brand_campaigns` (the real truth) | `base_pay_per_video_cents` | $10.00 |

So `managed_creators.base_pay` has **three contradictory interpretations** in
live code, none equal to the campaign's $10. The production payout path is yet
another writer — the `process_post_payment` RPC (not in this slice) — which
writes `total_paid_cents` directly instead of deriving it from the ledger. The
**existence of the `update-base` / `reprice-posts` override endpoints is itself
the tell**: ops built manual fixups for numbers the triggers got wrong. A
complete fix routes *every* writer through one canonical pay function.

> The `FINDINGS.md` deliverable asks you to name the real source of truth per
> value, the root cause of each ticket, and the fix direction (what becomes
> canonical, what stops being written, what one-time migration is needed).

### Status: investigation complete + demonstration fix written ✅
- **`FINDINGS.md` is fully written** — reproduced against the live seeded DB
  (queries + actual output quoted), all three tickets root-caused, source-of-truth
  table, fix direction, and a before/after table. Read it for the authoritative
  analysis.
- **`ASSIGNMENT/db/migrations/0001_fix_payment_source_of_truth.sql`** implements
  the fix direction. It is **idempotent** and, critically, **not auto-loaded** —
  it lives in a `db/migrations/` subdirectory, which the Postgres docker
  entrypoint does *not* scan (only `/docker-entrypoint-initdb.d` top-level files
  run, in name order; placing it there would make it run *before* `init.sql` and
  fail). Apply manually:
  ```bash
  docker exec -i assignment_db psql -U postgres -d assignment \
    < ASSIGNMENT/db/migrations/0001_fix_payment_source_of_truth.sql
  ```
  What it changes:
  1. **Base pay + milestones sourced from `brand_campaigns`** (joined via
     `managed_creators.job_id`), with `managed_creators` demoted to an explicit
     fallback — directly addresses TICKET-481.
  2. **Milestone JSON normalized** to canonical `{min_views, amount_cents}` via
     `canonicalize_milestones()`, and read **key-tolerantly** (`qualifying_bonus_cents()`
     accepts legacy `{views, bonus_cents}` too) — addresses TICKET-486.
  3. **`total_paid_cents` / `payment_status` projected from `creator_transactions`**
     via a new `AFTER INSERT/UPDATE/DELETE` trigger `trigger_sync_post_paid`
     (`sync_post_paid_from_ledger()`) — the ledger becomes the paid-money truth,
     addressing TICKET-490. `total_paid_cents` stops being a hand-written column.
  4. **One-time backfill** re-derives base pay/milestones/owed for every existing
     post and reconciles paid/status from the ledger. (Step 4e — auto-crediting
     missing wallet earnings — is left commented; moving money is a business call.)
  - Verified before/after on the live DB: Maria $1→$60 owed (bonus restored);
    Teo flips `paid`→`partially_paid` ($5 of $60). Forward checks mutate the
    throwaway container — `docker compose down -v && up -d` for a pristine seed.

---

## 9. Part 1: the three planted unit-test bugs — **FIXED ✅**

All in `lib/`, each was caught by a failing test. Each was a small, real logic
bug. All three are now fixed (logic-level fixes, no test edits) and the full
suite is green — **98/98 tests pass** (`pnpm test`).

1. **Rate limiter** — `lib/modules/phone-verification/rate-limit.ts`.
   Off-by-one: `if (entry.count <= maxAttempts)` allowed one extra attempt
   (limit 3 let through 4). **Fix:** `<=` → `<`. The first request seeds
   `count: 1` and each allowed request increments, so `<` blocks the
   `(max+1)`th request. Test: `rate-limit.test.ts`.
2. **Lookup classifier** — `lib/admin/lookup/classify.ts`. `AD_CODE_RE =
   /^[A-Z0-9]{4,5}$/` was too narrow (the docstring says ad codes are 4–12
   chars), so 6-char codes like `ABC123` / `ABCDEF` fell through to the
   `username` branch. **Fix:** `{4,5}` → `{4,12}`. Test: `classify.test.ts`.
3. **CPM earnings** — `lib/modules/cpm/utils.ts`. `calculateCpmEarnings` did
   `(views / 10000) * cpmRate` — CPM is per **1,000** views, so earnings came
   out 10× too low. **Fix:** `/ 10000` → `/ 1000`. Test:
   `lib/modules/cpm/__tests__/utils.test.ts`.

A larger **hidden** suite re-runs over the same modules at grading time, so the
fixes are logic-level (the assertions were never touched).

---

## 10. Components (`components/`)

- **`ui/`** — shadcn/Radix primitives (button, dialog, table, select, sheet,
  tabs, tooltip, …). Generated/configured via `components.json`.
- **`Admin/`** — the bulk. Notably **`AdminGrid/`**: a large set of AG Grid
  column-definition + cell-renderer modules (`creatorPostPaymentColumnDefs`,
  `cpmColumnDefs`, `brandCampaignColumnDefs`, etc.) — this is how the
  data-dense ops tables are built. Plus `BrandDetail/` (sectioned detail view
  with a brief editor), `CreatorWarmup/`, `SocialAccountInspector/`,
  `VideoReviews/`, and many dialogs.
- **`Cpm/`, `Brand/`, `Dashboard/`, `Portal/`** — feature components
  (`Portal/ContractPDF.tsx` renders the creator contract via
  `@react-pdf/renderer`).
- **`shared/`** — cross-feature: job cards/details/pricing, platform icons,
  lazy video player, charts (`PostsLast7DaysChart`), TikTok embed.

State/data fetching uses **TanStack Query** (`@tanstack/react-query`); contexts
in `lib/contexts/` (`AdminContext`, `AdminViewAsContext`, `MobileHeaderContext`).

---

## 11. Cross-cutting concerns

- **i18n** (`i18n.ts`, `i18n/routing.ts`, `lib/i18n/`) — 13 locales, each mapped
  to a country domain (`example.fr` → `fr`, etc.). A custom ESLint rule
  (`no-hardcoded-strings`) enforces translation usage; components fetch strings
  via `useComponentTranslations`.
- **Notifications / messaging** (`lib/notifications/`, `lib/messaging/`) — a
  fan-out system: in-app `messages` rows, email (`resend`/`nodemailer`), push
  (Expo tokens), and **Slack** ops alerts (`notifications/slack/*` — channels,
  payouts, cron, storage). `notify()` is the central entry point.
- **Analytics / error tracking** (`lib/analytics/`) — Sentry + PostHog
  (server + client). `captureError` / `captureDbError` / `captureStripeError`
  with typed `ErrorCategories` / `ErrorSeverity`; `with-error-tracking` and
  `capture-fire-and-forget` wrappers.
- **Storage** (`lib/storage/`) — Supabase Storage + Cloudflare R2 / S3,
  presigned + resumable (`tus`) uploads, quota tracking, URL helpers.
- **Video** (`lib/video/`) — AI-assisted: `analyze`, `download`,
  `process-reference-video`, `replication-review` (using Anthropic / Gemini /
  Groq SDKs).
- **Security** (`lib/utils/`) — `origin-validation`, `security`,
  `sanitize-slack`, DOMPurify; `lib/cron/auth.ts` timing-safe cron-secret check;
  `lib/mobile/auth.ts` JWT validation. `lib/env.ts` centralizes env var access.

---

## 12. Tooling, config & how to run

```bash
pnpm install                                   # deps
cd ASSIGNMENT && docker compose up -d && cd .. # Part-2 Postgres on :5433
pnpm test            # Part-1 unit tests (all green — 98/98 passing)
pnpm test:watch      # re-run on change
pnpm typecheck       # tsc --noEmit
pnpm lint            # eslint (incl. no-hardcoded-strings)
pnpm logs:capture    # export Claude/Codex session transcripts (grading)
```

- **You cannot fully `pnpm dev`** this slice — the web server needs Supabase +
  Stripe + other services not provided. The app is here to **read**.
- **Vitest** (`vitest.config.ts`, `tests/setup.ts`) — jsdom env, Testing
  Library. **Playwright** config/e2e are excluded from this slice (`tsconfig`
  `exclude`).
- **next.config.ts** — wrapped with Sentry + next-intl; strips `console.log`
  (keeps error/warn/info) in prod; server-action body limit 10mb with allowed
  origins `*.8x.social`; PostHog reverse-proxied via `/ph/*` rewrites; broad
  image `remotePatterns` (Supabase, TikTok/IG CDNs).
- **Connect to the DB:** `psql postgresql://postgres:postgres@localhost:5433/assignment`
  (`\dt` tables, `\d <table>`, `\df` functions, `SELECT` the seed).

---

## 13. Where the bodies are buried (gotchas for the next reader)

- **Same value, many homes.** A post's pay exists as: live config
  (`brand_campaigns` / `managed_creators`), a frozen trigger snapshot
  (`managed_creator_posts.*_cents`), and a ledger fact (`creator_transactions`).
  Nothing reconciles them. Always ask *which* copy a piece of code reads.
- **Triggers, not app code, freeze pay.** The numbers that show in the admin
  panel are computed in Postgres (`ASSIGNMENT/db/init.sql`), and the recalc
  trigger reads the **already-frozen** copies, so it can't "heal" a bad initial
  snapshot.
- **Two bonus-milestone shapes** (`{min_views, amount_cents}` vs `{views,
  bonus_cents}`) coexist in JSONB and silently read as NULL across the boundary.
- **`base_pay` is cents-in-a-NUMERIC**, easy to confuse with dollars; the `$1`
  bug is exactly this confusion.
- **Many writers, one column.** `managed_creator_posts.*_cents` is written by
  ≥4 paths with *different* formulas (create trigger, recalc trigger,
  `update-base` route, `reprice-posts` route, prod `process_post_payment` RPC).
  Editing one without the others just adds a fifth disagreeing number. The
  `update-base` / `reprice-posts` endpoints exist because ops needed to override
  trigger output by hand — a symptom, not a feature.
- **Service-role client bypasses RLS.** Any `createServiceRoleClient()` query
  without a manual user filter is a potential data leak — the mobile handlers
  and admin routes live on this knife-edge.
- **Two route-handler styles** (wrapped vs hand-rolled) — don't assume auth/
  validation is centralized; the admin area often does it inline.
- **Partial-success payouts.** A payout can succeed in the DB but skip/fail the
  Stripe leg; callers return `success: true` with an `error` note. "Paid" means
  "ledger says so," not "money moved."
- **This is a curated slice.** Missing layouts, the mobile catch-all route, and
  many tables referenced by the code (`cpm_submissions`, `creator_profiles`,
  `creator_wallet`, `users`, …) are not in `ASSIGNMENT/db` — only the
  payment-path tables are. Code references to other tables won't run locally.
```
