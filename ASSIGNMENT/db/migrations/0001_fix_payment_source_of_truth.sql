-- =====================================================================
-- 0001_fix_payment_source_of_truth.sql
--
-- Fixes the three payment tickets (481 / 486 / 490) at their shared root:
-- the payment path derived pay from `managed_creators` (a stale per-creator
-- copy) in the wrong VALUE (base pay) and wrong JSON SHAPE (bonus milestones),
-- and reconciled "paid" against a hand-written column instead of the ledger.
--
-- This migration:
--   1. Makes `brand_campaigns` the source of truth for base pay + milestones,
--      with `managed_creators` as an explicit fallback (not the default).
--   2. Normalizes bonus-milestone JSON to one canonical shape
--      {min_views, amount_cents}, and reads it key-tolerantly during transition.
--   3. Projects `total_paid_cents` / `payment_status` from the
--      `creator_transactions` ledger.
--   4. Backfills + recomputes every existing post.
--
-- NOT auto-loaded: it lives under db/migrations/ (a subdirectory), which the
-- Postgres docker entrypoint does NOT scan — so it won't run on a fresh boot
-- (where it would otherwise execute before init.sql and fail). Apply manually:
--
--   docker exec -i assignment_db psql -U postgres -d assignment \
--     < ASSIGNMENT/db/migrations/0001_fix_payment_source_of_truth.sql
--
-- Idempotent: safe to run more than once.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 0. Reusable helpers (key-tolerant — accept canonical OR legacy keys)
-- ---------------------------------------------------------------------

-- Canonical milestone shape: {min_views, amount_cents}.
-- Legacy shape: {views, bonus_cents}. Coalesce so either is accepted.
CREATE OR REPLACE FUNCTION canonicalize_milestones(p jsonb)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'min_views',    COALESCE((e->>'min_views')::int,    (e->>'views')::int),
        'amount_cents', COALESCE((e->>'amount_cents')::int, (e->>'bonus_cents')::int)
      )
      ORDER BY COALESCE((e->>'min_views')::int, (e->>'views')::int)
    ),
    '[]'::jsonb
  )
  FROM jsonb_array_elements(COALESCE(p, '[]'::jsonb)) e
  WHERE e ? 'min_views' OR e ? 'views';   -- skip malformed entries
$$;

-- Highest qualifying bonus for a given view count, key-tolerant.
CREATE OR REPLACE FUNCTION qualifying_bonus_cents(p_milestones jsonb, p_views int)
RETURNS int
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(
    MAX(COALESCE((e->>'amount_cents')::int, (e->>'bonus_cents')::int)),
    0
  )
  FROM jsonb_array_elements(COALESCE(p_milestones, '[]'::jsonb)) e
  WHERE COALESCE((e->>'min_views')::int, (e->>'views')::int) <= p_views;
$$;

-- ---------------------------------------------------------------------
-- 1. Corrected INSERT trigger: snapshot the CORRECT contracted values
--    (base pay + milestones) from brand_campaigns at post-creation time.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_managed_creator_post()
RETURNS TRIGGER AS $$
DECLARE
    v_mc RECORD;
    v_bc RECORD;
    v_views INTEGER;
    v_base_pay_cents INTEGER;
    v_milestones JSONB;
    v_calculated_pay INTEGER;
    v_bonus INTEGER;
    v_total_owed INTEGER;
BEGIN
    -- Match the active managed creator by social account (unchanged).
    SELECT
        mc.id,
        mc.job_id,
        mc.cpm_rate,
        mc.max_pay_cents,
        COALESCE(mc.base_pay, 0)::INTEGER          AS base_pay_cents,      -- fallback only
        COALESCE(mc.bonus_milestones, '[]'::jsonb) AS bonus_milestones     -- fallback only
    INTO v_mc
    FROM managed_creators mc
    WHERE mc.is_active = true
      AND (
          (NEW.instagram_account_id IS NOT NULL AND mc.instagram_account_id = NEW.instagram_account_id)
          OR (NEW.tiktok_account_id IS NOT NULL AND mc.tiktok_account_id = NEW.tiktok_account_id)
          OR (NEW.youtube_account_id IS NOT NULL AND mc.youtube_account_id = NEW.youtube_account_id)
      )
    LIMIT 1;

    IF v_mc.id IS NULL THEN
        RETURN NEW;
    END IF;

    -- SOURCE OF TRUTH: the brand campaign for this creator's job.
    SELECT bc.base_pay_per_video_cents, bc.bonus_milestones
    INTO v_bc
    FROM brand_campaigns bc
    WHERE bc.job_id = v_mc.job_id
    LIMIT 1;

    v_views := COALESCE(NEW.latest_views, 0);

    -- Base pay: campaign wins; managed_creators.base_pay is only a fallback
    -- when no campaign row exists. (A real per-creator override would be an
    -- explicit, separate column — never the silently-stale `base_pay`.)
    v_base_pay_cents := COALESCE(v_bc.base_pay_per_video_cents, v_mc.base_pay_cents, 0);

    -- Milestones: take the campaign's, normalized to canonical shape.
    v_milestones := canonicalize_milestones(
        COALESCE(v_bc.bonus_milestones, v_mc.bonus_milestones, '[]'::jsonb)
    );

    IF v_mc.cpm_rate IS NOT NULL AND v_mc.cpm_rate > 0 THEN
        v_calculated_pay := (v_mc.cpm_rate * v_views) / 1000;
    ELSE
        v_calculated_pay := v_base_pay_cents;
    END IF;

    v_bonus := qualifying_bonus_cents(v_milestones, v_views);

    v_total_owed := v_calculated_pay + v_bonus;
    IF v_mc.max_pay_cents IS NOT NULL AND v_total_owed > v_mc.max_pay_cents THEN
        v_total_owed := v_mc.max_pay_cents;
    END IF;

    INSERT INTO managed_creator_posts (
        managed_creator_id, post_id, base_pay_cents, cpm_rate, max_pay_cents,
        bonus_milestones, calculated_pay_cents, bonus_cents, total_owed_cents
    ) VALUES (
        v_mc.id, NEW.id, v_base_pay_cents, v_mc.cpm_rate, v_mc.max_pay_cents,
        v_milestones, v_calculated_pay, v_bonus, v_total_owed
    )
    ON CONFLICT (post_id) DO NOTHING;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- 2. Corrected RECALC trigger: recompute owed from the (now correct)
--    snapshot using CURRENT views; key-tolerant bonus read.
--    Rate stays frozen (contracted); owed stays live. payment_status is
--    a function of the ledger-projected total_paid_cents (see step 3).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION recalculate_managed_creator_post_payment()
RETURNS TRIGGER AS $$
DECLARE
    v_mcp RECORD;
    v_views INTEGER;
    v_calculated_pay INTEGER;
    v_bonus INTEGER;
    v_total_owed INTEGER;
BEGIN
    SELECT * INTO v_mcp
    FROM managed_creator_posts
    WHERE post_id = NEW.post_id;

    IF v_mcp.id IS NULL THEN
        RETURN NEW;
    END IF;

    v_views := COALESCE(NEW.views, 0);

    IF v_mcp.cpm_rate IS NOT NULL AND v_mcp.cpm_rate > 0 THEN
        v_calculated_pay := (v_mcp.cpm_rate * v_views) / 1000;
    ELSE
        v_calculated_pay := v_mcp.base_pay_cents;
    END IF;

    v_bonus := qualifying_bonus_cents(v_mcp.bonus_milestones, v_views);

    v_total_owed := v_calculated_pay + v_bonus;
    IF v_mcp.max_pay_cents IS NOT NULL AND v_total_owed > v_mcp.max_pay_cents THEN
        v_total_owed := v_mcp.max_pay_cents;
    END IF;

    UPDATE managed_creator_posts
    SET
        calculated_pay_cents = v_calculated_pay,
        bonus_cents = v_bonus,
        total_owed_cents = v_total_owed,
        payment_status = CASE
            WHEN total_paid_cents >= v_total_owed AND v_total_owed > 0 THEN 'paid'
            WHEN total_paid_cents > 0 AND total_paid_cents < v_total_owed THEN 'partially_paid'
            ELSE 'unpaid'
        END,
        updated_at = NOW()
    WHERE id = v_mcp.id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- 3. Ledger projection: total_paid_cents / payment_status are DERIVED
--    from creator_transactions, never written by hand.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_post_paid_from_ledger()
RETURNS TRIGGER AS $$
DECLARE
    v_post_id UUID;
    v_paid INTEGER;
    v_owed INTEGER;
BEGIN
    v_post_id := COALESCE(NEW.managed_creator_post_id, OLD.managed_creator_post_id);
    IF v_post_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    -- "Paid for this post" = sum of positive ledger entries tied to it.
    SELECT COALESCE(SUM(amount_cents), 0) INTO v_paid
    FROM creator_transactions
    WHERE managed_creator_post_id = v_post_id
      AND amount_cents > 0;

    SELECT total_owed_cents INTO v_owed
    FROM managed_creator_posts
    WHERE id = v_post_id;

    UPDATE managed_creator_posts
    SET total_paid_cents = v_paid,
        payment_status = CASE
            WHEN v_paid >= v_owed AND v_owed > 0 THEN 'paid'
            WHEN v_paid > 0 AND v_paid < v_owed THEN 'partially_paid'
            ELSE 'unpaid'
        END,
        updated_at = NOW()
    WHERE id = v_post_id;

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_sync_post_paid ON creator_transactions;
CREATE TRIGGER trigger_sync_post_paid
    AFTER INSERT OR UPDATE OR DELETE ON creator_transactions
    FOR EACH ROW
    EXECUTE FUNCTION sync_post_paid_from_ledger();

-- ---------------------------------------------------------------------
-- 4. One-time backfill of existing rows
-- ---------------------------------------------------------------------

-- 4a. Normalize stored milestone JSON to canonical shape.
UPDATE managed_creators
SET bonus_milestones = canonicalize_milestones(bonus_milestones)
WHERE bonus_milestones IS NOT NULL;

-- 4b. Re-derive each post's frozen base pay + milestones from the campaign.
UPDATE managed_creator_posts mcp
SET base_pay_cents   = COALESCE(bc.base_pay_per_video_cents, mcp.base_pay_cents),
    bonus_milestones = canonicalize_milestones(
                         COALESCE(bc.bonus_milestones, mcp.bonus_milestones))
FROM managed_creators mc
LEFT JOIN brand_campaigns bc ON bc.job_id = mc.job_id
WHERE mc.id = mcp.managed_creator_id;

-- 4c. Recompute calculated/bonus/owed from corrected snapshot + current views.
UPDATE managed_creator_posts mcp
SET calculated_pay_cents = CASE
        WHEN mcp.cpm_rate IS NOT NULL AND mcp.cpm_rate > 0
        THEN (mcp.cpm_rate * p.latest_views) / 1000
        ELSE mcp.base_pay_cents
    END,
    bonus_cents = qualifying_bonus_cents(mcp.bonus_milestones, p.latest_views),
    total_owed_cents = LEAST(
        (CASE
            WHEN mcp.cpm_rate IS NOT NULL AND mcp.cpm_rate > 0
            THEN (mcp.cpm_rate * p.latest_views) / 1000
            ELSE mcp.base_pay_cents
         END) + qualifying_bonus_cents(mcp.bonus_milestones, p.latest_views),
        COALESCE(mcp.max_pay_cents, 2147483647)
    ),
    updated_at = NOW()
FROM posts p
WHERE p.id = mcp.post_id;

-- 4d. Reconcile total_paid_cents + payment_status from the ledger.
UPDATE managed_creator_posts mcp
SET total_paid_cents = COALESCE(l.paid, 0)
FROM (
    SELECT managed_creator_post_id, SUM(amount_cents) AS paid
    FROM creator_transactions
    WHERE amount_cents > 0
    GROUP BY managed_creator_post_id
) l
WHERE l.managed_creator_post_id = mcp.id;

UPDATE managed_creator_posts
SET payment_status = CASE
        WHEN total_paid_cents >= total_owed_cents AND total_owed_cents > 0 THEN 'paid'
        WHEN total_paid_cents > 0 AND total_paid_cents < total_owed_cents THEN 'partially_paid'
        ELSE 'unpaid'
    END,
    updated_at = NOW();

-- 4e. OPTIONAL (commented — crediting money is a business decision):
--     backfill missing ledger earnings so each creator's wallet equals what
--     they're owed. Enable only if product wants auto-credit on migration.
-- INSERT INTO creator_transactions (user_id, managed_creator_post_id, amount_cents, type)
-- SELECT mc.linked_user_id, mcp.id,
--        mcp.total_owed_cents - mcp.total_paid_cents, 'earning'
-- FROM managed_creator_posts mcp
-- JOIN managed_creators mc ON mc.id = mcp.managed_creator_id
-- WHERE mc.linked_user_id IS NOT NULL
--   AND mcp.total_owed_cents > mcp.total_paid_cents;

COMMIT;
