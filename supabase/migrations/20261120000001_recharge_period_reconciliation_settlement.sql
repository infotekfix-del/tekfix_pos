-- ============================================================================
-- TEKFIX ERP - QUICK RECHARGE: PERIOD RECONCILIATION + OPERATOR-WISE
-- DISTRIBUTOR SETTLEMENT (v2)
-- ADDITIVE ONLY: no existing row is updated or deleted, no column dropped,
-- no existing constraint removed. Integer paise only.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. New audit columns on existing ledgers (nullable / defaulted)
-- ----------------------------------------------------------------------------
ALTER TABLE public.recharge_wallet_logs
    ADD COLUMN IF NOT EXISTS adjustment_sign SMALLINT NOT NULL DEFAULT 1,
    ADD COLUMN IF NOT EXISTS category TEXT,
    ADD COLUMN IF NOT EXISTS period_id TEXT,
    ADD COLUMN IF NOT EXISTS idempotency_key TEXT,
    ADD COLUMN IF NOT EXISTS reason TEXT,
    ADD COLUMN IF NOT EXISTS distributor_id TEXT,
    ADD COLUMN IF NOT EXISTS business_date DATE;

DO $$ BEGIN
    ALTER TABLE public.recharge_wallet_logs
        ADD CONSTRAINT chk_wallet_logs_adjustment_sign CHECK (adjustment_sign IN (-1, 1));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE UNIQUE INDEX IF NOT EXISTS idx_wallet_logs_idempotency
ON public.recharge_wallet_logs (shop_id, idempotency_key)
WHERE idempotency_key IS NOT NULL;

ALTER TABLE public.recharge_distributor_ledger
    ADD COLUMN IF NOT EXISTS operator TEXT,
    ADD COLUMN IF NOT EXISTS idempotency_key TEXT,
    ADD COLUMN IF NOT EXISTS signed_balance_before_paise BIGINT,
    ADD COLUMN IF NOT EXISTS signed_balance_after_paise BIGINT,
    ADD COLUMN IF NOT EXISTS payment_date DATE,
    ADD COLUMN IF NOT EXISTS reference_no TEXT,
    ADD COLUMN IF NOT EXISTS created_by TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_distributor_ledger_idempotency
ON public.recharge_distributor_ledger (shop_id, idempotency_key)
WHERE idempotency_key IS NOT NULL;

-- Opening balance carried over from the pre-v2 single account: the part of
-- outstanding_balance_paise that the ledger rows do not explain. Frozen once.
ALTER TABLE public.recharge_distributors
    ADD COLUMN IF NOT EXISTS default_operator TEXT,
    ADD COLUMN IF NOT EXISTS legacy_opening_paise BIGINT NOT NULL DEFAULT 0;

-- ----------------------------------------------------------------------------
-- 2. Period snapshots (morning, closing, reference). Immutable.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.recharge_period_snapshots (
    shop_id TEXT NOT NULL,
    snapshot_id TEXT NOT NULL,
    operator TEXT NOT NULL CHECK (operator IN ('airtel', 'jio', 'vi', 'bsnl')),
    kind TEXT NOT NULL CHECK (kind IN ('morning', 'closing', 'reference')),
    period_id TEXT NOT NULL,
    previous_closing_at TIMESTAMPTZ,
    actual_paise BIGINT NOT NULL CHECK (actual_paise >= 0),
    expected_paise BIGINT,
    raw_difference_paise BIGINT,
    already_recorded_paise BIGINT,
    unexplained_paise BIGINT,
    variance_paise BIGINT,
    status TEXT NOT NULL,
    reason TEXT,
    business_date DATE NOT NULL,
    idempotency_key TEXT NOT NULL,
    created_by TEXT NOT NULL,
    device_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (shop_id, snapshot_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_period_snapshots_one_per_period
ON public.recharge_period_snapshots (shop_id, operator, period_id, kind);

CREATE UNIQUE INDEX IF NOT EXISTS idx_period_snapshots_idempotency
ON public.recharge_period_snapshots (shop_id, idempotency_key);

CREATE INDEX IF NOT EXISTS idx_period_snapshots_closings
ON public.recharge_period_snapshots (shop_id, operator, created_at DESC)
WHERE kind IN ('closing', 'reference');

ALTER TABLE public.recharge_period_snapshots ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Deny direct public client access" ON public.recharge_period_snapshots;
CREATE POLICY "Deny direct public client access" ON public.recharge_period_snapshots
    FOR ALL TO anon, authenticated USING (false);

DROP TRIGGER IF EXISTS trg_prevent_period_snapshot_tampering ON public.recharge_period_snapshots;
CREATE TRIGGER trg_prevent_period_snapshot_tampering
BEFORE UPDATE OR DELETE ON public.recharge_period_snapshots
FOR EACH ROW EXECUTE FUNCTION public.recharge_prevent_ledger_tampering();

DROP TRIGGER IF EXISTS trg_prevent_distributor_ledger_tampering ON public.recharge_distributor_ledger;
CREATE TRIGGER trg_prevent_distributor_ledger_tampering
BEFORE UPDATE OR DELETE ON public.recharge_distributor_ledger
FOR EACH ROW EXECUTE FUNCTION public.recharge_prevent_ledger_tampering();

-- ----------------------------------------------------------------------------
-- 3. One-time, read-only derivation of the legacy opening per distributor.
--    Only the two NEW columns are written; existing values are untouched.
-- ----------------------------------------------------------------------------
UPDATE public.recharge_distributors d
SET legacy_opening_paise = d.outstanding_balance_paise - COALESCE((
        SELECT SUM(CASE WHEN l.entry_type = 'credit_extended' THEN l.amount_paise ELSE -l.amount_paise END)
        FROM public.recharge_distributor_ledger l
        WHERE l.shop_id = d.shop_id AND l.distributor_id = d.distributor_id), 0),
    default_operator = COALESCE(d.default_operator, (
        SELECT lower(w.operator)
        FROM public.recharge_distributor_ledger l
        JOIN public.recharge_wallets w ON w.shop_id = l.shop_id AND w.wallet_id = l.wallet_id
        WHERE l.shop_id = d.shop_id AND l.distributor_id = d.distributor_id
        GROUP BY lower(w.operator)
        ORDER BY COUNT(*) DESC, lower(w.operator)
        LIMIT 1))
WHERE d.legacy_opening_paise = 0 AND d.default_operator IS NULL;

-- ----------------------------------------------------------------------------
-- 4. Helpers
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recharge_acc_wallet_id(p_operator TEXT)
RETURNS TEXT AS $$
    SELECT CASE lower(p_operator)
        WHEN 'airtel' THEN 'WALLET_AIRTEL'
        WHEN 'jio' THEN 'WALLET_JIO'
        WHEN 'vi' THEN 'WALLET_VI'
        WHEN 'bsnl' THEN 'WALLET_BSNL'
    END;
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION public.recharge_acc_ist_date(p_ts TIMESTAMPTZ)
RETURNS DATE AS $$
    SELECT (p_ts AT TIME ZONE 'Asia/Kolkata')::date;
$$ LANGUAGE sql IMMUTABLE;

-- Last verified closing (or reference balance) for an operator.
CREATE OR REPLACE FUNCTION public.recharge_acc_last_closing(p_shop_id TEXT, p_operator TEXT)
RETURNS public.recharge_period_snapshots AS $$
    SELECT * FROM public.recharge_period_snapshots
    WHERE shop_id = p_shop_id AND operator = lower(p_operator) AND kind IN ('closing', 'reference')
    ORDER BY created_at DESC
    LIMIT 1;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION public.recharge_acc_period_id(p_operator TEXT, p_from TIMESTAMPTZ)
RETURNS TEXT AS $$
    SELECT lower(p_operator) || '_' || COALESCE(to_char(p_from AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), 'GENESIS');
$$ LANGUAGE sql IMMUTABLE;

-- Wallet movements of one operator in (p_from, p_to]. Kinds match the app's
-- WalletMovementKind names. A debit of a still-pending recharge is flagged.
CREATE OR REPLACE FUNCTION public.recharge_acc_movements(
    p_shop_id TEXT, p_operator TEXT, p_from TIMESTAMPTZ, p_to TIMESTAMPTZ
) RETURNS TABLE (kind TEXT, amount_paise BIGINT, at TIMESTAMPTZ, reference_id TEXT, pending BOOLEAN) AS $$
    SELECT
        CASE
            WHEN l.entry_type = 'debit' THEN 'rechargeDebit'
            WHEN l.entry_type IN ('topup', 'float_deposit') THEN 'topUpOwn'
            WHEN l.entry_type IN ('distributor_credit', 'distributor_refill') THEN 'creditLoad'
            WHEN l.entry_type IN ('refund', 'reversal') THEN 'refundCredit'
            WHEN l.entry_type = 'credit' AND l.category = 'bonus' THEN 'bonus'
            WHEN l.entry_type = 'credit' THEN 'commissionCredit'
            ELSE 'adjustment'
        END,
        CASE WHEN l.entry_type = 'adjustment' THEN l.amount_paise * l.adjustment_sign ELSE l.amount_paise END,
        l.created_at,
        COALESCE(l.txn_key, l.log_id),
        COALESCE(l.entry_type = 'debit' AND t.status = 'pending', false)
    FROM public.recharge_wallet_logs l
    LEFT JOIN public.recharge_transactions t ON t.shop_id = l.shop_id AND t.txn_key = l.txn_key
    WHERE l.shop_id = p_shop_id
      AND l.wallet_id = public.recharge_acc_wallet_id(p_operator)
      AND (p_from IS NULL OR l.created_at > p_from)
      AND (p_to IS NULL OR l.created_at <= p_to)
    ORDER BY l.created_at;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION public.recharge_acc_signed(p_kind TEXT, p_amount BIGINT, p_pending BOOLEAN)
RETURNS BIGINT AS $$
    SELECT CASE WHEN p_kind IN ('rechargeDebit', 'commissionClawback') THEN -p_amount ELSE p_amount END;
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION public.recharge_acc_validate(
    p_operator TEXT, p_amount BIGINT, p_idempotency_key TEXT, p_allow_negative BOOLEAN, p_allow_zero BOOLEAN
) RETURNS VOID AS $$
BEGIN
    IF lower(COALESCE(p_operator, '')) NOT IN ('airtel', 'jio', 'vi', 'bsnl') THEN
        RAISE EXCEPTION 'INVALID_OPERATOR: %', p_operator;
    END IF;
    IF p_idempotency_key IS NULL OR p_idempotency_key !~ '^[A-Za-z0-9_\-:.]{8,120}$' THEN
        RAISE EXCEPTION 'INVALID_KEY';
    END IF;
    IF p_amount IS NULL OR abs(p_amount) > 100000000 THEN
        RAISE EXCEPTION 'AMOUNT_LIMIT: amount must be within Rs 10,00,000';
    END IF;
    IF p_amount = 0 AND NOT p_allow_zero THEN
        RAISE EXCEPTION 'INVALID_AMOUNT: amount cannot be zero';
    END IF;
    IF p_amount < 0 AND NOT p_allow_negative THEN
        RAISE EXCEPTION 'INVALID_AMOUNT: amount must be positive';
    END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ----------------------------------------------------------------------------
-- 5. Read: period state for the four operators
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recharge_acc_period_state(p_shop_id TEXT)
RETURNS JSONB AS $$
DECLARE
    v_op TEXT;
    v_prev public.recharge_period_snapshots;
    v_pid TEXT;
    v_morning public.recharge_period_snapshots;
    v_classified BIGINT;
    v_out JSONB := '[]'::jsonb;
BEGIN
    FOREACH v_op IN ARRAY ARRAY['airtel', 'jio', 'vi', 'bsnl'] LOOP
        v_prev := public.recharge_acc_last_closing(p_shop_id, v_op);
        v_pid := public.recharge_acc_period_id(v_op, v_prev.created_at);
        SELECT * INTO v_morning FROM public.recharge_period_snapshots
        WHERE shop_id = p_shop_id AND operator = v_op AND period_id = v_pid AND kind = 'morning';
        SELECT COALESCE(SUM(amount_paise * adjustment_sign), 0) INTO v_classified
        FROM public.recharge_wallet_logs
        WHERE shop_id = p_shop_id AND period_id = v_pid AND category IS NOT NULL
          AND wallet_id = public.recharge_acc_wallet_id(v_op);

        v_out := v_out || jsonb_build_object(
            'operator', v_op,
            'period_id', v_pid,
            'previous_closing', CASE WHEN v_prev.snapshot_id IS NULL THEN NULL ELSE jsonb_build_object(
                'actual_paise', v_prev.actual_paise,
                'at', v_prev.created_at,
                'period_id', v_prev.period_id) END,
            'morning', CASE WHEN v_morning.snapshot_id IS NULL THEN NULL ELSE jsonb_build_object(
                'morning_actual_paise', v_morning.actual_paise,
                'at', v_morning.created_at,
                'unexplained_paise', v_morning.unexplained_paise,
                'classified_paise', v_classified) END,
            'movements', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                    'kind', m.kind, 'amount_paise', m.amount_paise, 'at', m.at,
                    'reference_id', m.reference_id, 'pending', m.pending) ORDER BY m.at)
                FROM public.recharge_acc_movements(p_shop_id, v_op, v_prev.created_at, NULL) m), '[]'::jsonb)
        );
    END LOOP;
    RETURN jsonb_build_object('success', true, 'operators', v_out);
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- ----------------------------------------------------------------------------
-- 6. Morning verification (one per operator per period, idempotent)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recharge_acc_verify_morning(
    p_shop_id TEXT, p_operator TEXT, p_morning_paise BIGINT,
    p_idempotency_key TEXT, p_staff_id TEXT, p_device_id TEXT
) RETURNS JSONB AS $$
DECLARE
    v_op TEXT := lower(p_operator);
    v_existing public.recharge_period_snapshots;
    v_prev public.recharge_period_snapshots;
    v_pid TEXT;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_recorded BIGINT;
    v_raw BIGINT;
    v_unexplained BIGINT;
    v_status TEXT;
BEGIN
    PERFORM public.recharge_acc_validate(v_op, p_morning_paise, p_idempotency_key, false, true);
    PERFORM pg_advisory_xact_lock(hashtext('recharge_acc:' || p_shop_id || ':' || v_op));

    SELECT * INTO v_existing FROM public.recharge_period_snapshots
    WHERE shop_id = p_shop_id AND idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN jsonb_build_object('success', true, 'replayed', true, 'reference_id', v_existing.snapshot_id,
            'period_id', v_existing.period_id, 'unexplainedPaise', v_existing.unexplained_paise,
            'status', v_existing.status);
    END IF;

    v_prev := public.recharge_acc_last_closing(p_shop_id, v_op);
    IF v_prev.snapshot_id IS NULL THEN
        RAISE EXCEPTION 'PREVIOUS_CLOSING_MISSING: enter a verified reference balance first';
    END IF;
    v_pid := public.recharge_acc_period_id(v_op, v_prev.created_at);

    IF EXISTS (SELECT 1 FROM public.recharge_period_snapshots
               WHERE shop_id = p_shop_id AND operator = v_op AND period_id = v_pid AND kind = 'morning') THEN
        RAISE EXCEPTION 'DUPLICATE_MORNING: morning balance already entered for this period';
    END IF;

    SELECT COALESCE(SUM(public.recharge_acc_signed(m.kind, m.amount_paise, m.pending)), 0) INTO v_recorded
    FROM public.recharge_acc_movements(p_shop_id, v_op, v_prev.created_at, v_now) m;

    v_raw := p_morning_paise - v_prev.actual_paise;
    v_unexplained := v_raw - v_recorded;
    v_status := CASE WHEN v_unexplained = 0 THEN 'verified'
                     WHEN v_unexplained > 0 THEN 'pendingVerification'
                     ELSE 'discrepancy' END;

    INSERT INTO public.recharge_period_snapshots (
        shop_id, snapshot_id, operator, kind, period_id, previous_closing_at, actual_paise,
        raw_difference_paise, already_recorded_paise, unexplained_paise, status,
        business_date, idempotency_key, created_by, device_id, created_at
    ) VALUES (
        p_shop_id, 'MORNING_' || v_pid, v_op, 'morning', v_pid, v_prev.created_at, p_morning_paise,
        v_raw, v_recorded, v_unexplained, v_status,
        public.recharge_acc_ist_date(v_now), p_idempotency_key, p_staff_id, p_device_id, v_now
    );

    INSERT INTO public.recharge_audit_logs (shop_id, audit_id, event_type, actor_uid, device_id, entity_id, payload)
    VALUES (p_shop_id, gen_random_uuid()::text, 'ACC_MORNING_VERIFY', p_staff_id, p_device_id, 'MORNING_' || v_pid,
        jsonb_build_object('operator', v_op, 'raw', v_raw, 'recorded', v_recorded, 'unexplained', v_unexplained));

    RETURN jsonb_build_object('success', true, 'replayed', false, 'reference_id', 'MORNING_' || v_pid,
        'periodId', v_pid, 'rawDifferencePaise', v_raw, 'alreadyRecordedPaise', v_recorded,
        'unexplainedPaise', v_unexplained, 'status', v_status);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ----------------------------------------------------------------------------
-- 7. Reference balance (only when no verified closing exists yet)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recharge_acc_reference_balance(
    p_shop_id TEXT, p_operator TEXT, p_balance_paise BIGINT, p_reason TEXT,
    p_idempotency_key TEXT, p_staff_id TEXT, p_device_id TEXT
) RETURNS JSONB AS $$
DECLARE
    v_op TEXT := lower(p_operator);
    v_existing public.recharge_period_snapshots;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_pid TEXT := public.recharge_acc_period_id(lower(p_operator), NULL);
BEGIN
    PERFORM public.recharge_acc_validate(v_op, p_balance_paise, p_idempotency_key, false, true);
    IF COALESCE(trim(p_reason), '') = '' THEN RAISE EXCEPTION 'REASON_REQUIRED'; END IF;
    PERFORM pg_advisory_xact_lock(hashtext('recharge_acc:' || p_shop_id || ':' || v_op));

    SELECT * INTO v_existing FROM public.recharge_period_snapshots
    WHERE shop_id = p_shop_id AND idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN jsonb_build_object('success', true, 'replayed', true, 'reference_id', v_existing.snapshot_id);
    END IF;
    IF (public.recharge_acc_last_closing(p_shop_id, v_op)).snapshot_id IS NOT NULL THEN
        RAISE EXCEPTION 'REFERENCE_NOT_ALLOWED: a verified closing exists; use a correction adjustment';
    END IF;

    INSERT INTO public.recharge_period_snapshots (
        shop_id, snapshot_id, operator, kind, period_id, actual_paise, status, reason,
        business_date, idempotency_key, created_by, device_id, created_at
    ) VALUES (
        p_shop_id, 'REF_' || v_op || '_' || p_idempotency_key, v_op, 'reference', v_pid, p_balance_paise,
        'verified', p_reason, public.recharge_acc_ist_date(v_now), p_idempotency_key, p_staff_id, p_device_id, v_now
    );

    INSERT INTO public.recharge_audit_logs (shop_id, audit_id, event_type, actor_uid, device_id, entity_id, payload)
    VALUES (p_shop_id, gen_random_uuid()::text, 'ACC_REFERENCE_BALANCE', p_staff_id, p_device_id, v_op,
        jsonb_build_object('balance', p_balance_paise, 'reason', p_reason));

    RETURN jsonb_build_object('success', true, 'replayed', false, 'reference_id', 'REF_' || v_op || '_' || p_idempotency_key);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ----------------------------------------------------------------------------
-- 8. Classified posting of an unexplained amount / documented adjustment.
--    Moves the live wallet balance and, for a distributor-credit top-up,
--    the distributor payable in the same transaction.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recharge_acc_post_classified(
    p_shop_id TEXT, p_operator TEXT, p_category TEXT, p_amount_paise BIGINT, p_reason TEXT,
    p_transaction_date TIMESTAMPTZ, p_distributor_id TEXT,
    p_idempotency_key TEXT, p_staff_id TEXT, p_staff_name TEXT, p_device_id TEXT
) RETURNS JSONB AS $$
DECLARE
    v_op TEXT := lower(p_operator);
    v_wallet_id TEXT := public.recharge_acc_wallet_id(p_operator);
    v_is_adj BOOLEAN := p_category IN ('manualCorrection', 'otherAdjustment');
    v_entry_type TEXT;
    v_prev public.recharge_period_snapshots;
    v_pid TEXT;
    v_morning public.recharge_period_snapshots;
    v_classified BIGINT;
    v_wallet RECORD;
    v_dist RECORD;
    v_before BIGINT;
    v_after BIGINT;
    v_abs BIGINT := abs(p_amount_paise);
    v_now TIMESTAMPTZ := clock_timestamp();
    v_log_id TEXT := 'ACC_' || p_idempotency_key;
BEGIN
    IF p_category NOT IN ('topUpOwn', 'topUpDistributorCredit', 'refund', 'bonus',
                          'commissionCredit', 'manualCorrection', 'otherAdjustment') THEN
        RAISE EXCEPTION 'INVALID_CATEGORY: %', p_category;
    END IF;
    PERFORM public.recharge_acc_validate(v_op, p_amount_paise, p_idempotency_key, v_is_adj, false);
    IF COALESCE(trim(p_reason), '') = '' THEN RAISE EXCEPTION 'REASON_REQUIRED'; END IF;
    IF p_transaction_date IS NULL OR p_transaction_date > v_now + interval '5 minutes' THEN
        RAISE EXCEPTION 'FUTURE_DATE: date cannot be in the future';
    END IF;
    IF p_category = 'topUpDistributorCredit' AND COALESCE(p_distributor_id, '') = '' THEN
        RAISE EXCEPTION 'DISTRIBUTOR_REQUIRED';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('recharge_acc:' || p_shop_id || ':' || v_op));

    IF EXISTS (SELECT 1 FROM public.recharge_wallet_logs WHERE shop_id = p_shop_id AND idempotency_key = p_idempotency_key) THEN
        RETURN jsonb_build_object('success', true, 'replayed', true, 'reference_id', v_log_id);
    END IF;

    v_prev := public.recharge_acc_last_closing(p_shop_id, v_op);
    IF v_prev.snapshot_id IS NOT NULL AND p_transaction_date <= v_prev.created_at AND NOT v_is_adj THEN
        RAISE EXCEPTION 'LOCKED_PERIOD: that period is locked; use a correction adjustment';
    END IF;
    v_pid := public.recharge_acc_period_id(v_op, v_prev.created_at);

    SELECT * INTO v_morning FROM public.recharge_period_snapshots
    WHERE shop_id = p_shop_id AND operator = v_op AND period_id = v_pid AND kind = 'morning';
    IF FOUND AND NOT v_is_adj THEN
        SELECT COALESCE(SUM(amount_paise * adjustment_sign), 0) INTO v_classified
        FROM public.recharge_wallet_logs
        WHERE shop_id = p_shop_id AND period_id = v_pid AND category IS NOT NULL AND wallet_id = v_wallet_id;
        IF p_amount_paise > v_morning.unexplained_paise - v_classified THEN
            RAISE EXCEPTION 'EXCEEDS_UNEXPLAINED: remaining unexplained is % paise', v_morning.unexplained_paise - v_classified;
        END IF;
    END IF;

    SELECT * INTO v_wallet FROM public.recharge_wallets
    WHERE shop_id = p_shop_id AND wallet_id = v_wallet_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Wallet % not found', v_wallet_id; END IF;
    v_before := v_wallet.total_balance_paise;

    v_entry_type := CASE p_category
        WHEN 'topUpOwn' THEN 'topup'
        WHEN 'topUpDistributorCredit' THEN 'distributor_credit'
        WHEN 'refund' THEN 'refund'
        WHEN 'bonus' THEN 'credit'
        WHEN 'commissionCredit' THEN 'credit'
        ELSE 'adjustment' END;

    IF p_category = 'topUpDistributorCredit' THEN
        SELECT * INTO v_dist FROM public.recharge_distributors
        WHERE shop_id = p_shop_id AND distributor_id = p_distributor_id FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'UNKNOWN_DISTRIBUTOR: %', p_distributor_id; END IF;
        UPDATE public.recharge_wallets
        SET distributor_credit_balance_paise = distributor_credit_balance_paise + v_abs, last_updated_at = v_now
        WHERE shop_id = p_shop_id AND wallet_id = v_wallet_id;
    ELSIF p_amount_paise >= 0 THEN
        UPDATE public.recharge_wallets
        SET own_prepaid_balance_paise = own_prepaid_balance_paise + v_abs, last_updated_at = v_now
        WHERE shop_id = p_shop_id AND wallet_id = v_wallet_id;
    ELSE
        IF v_wallet.own_prepaid_balance_paise < v_abs THEN
            RAISE EXCEPTION 'INSUFFICIENT_BALANCE: own balance % is less than correction %', v_wallet.own_prepaid_balance_paise, v_abs;
        END IF;
        UPDATE public.recharge_wallets
        SET own_prepaid_balance_paise = own_prepaid_balance_paise - v_abs, last_updated_at = v_now
        WHERE shop_id = p_shop_id AND wallet_id = v_wallet_id;
    END IF;
    v_after := v_before + p_amount_paise;

    INSERT INTO public.recharge_wallet_logs (
        shop_id, log_id, wallet_id, entry_type, amount_paise, balance_before_paise, balance_after_paise,
        description, staff_id, staff_name, created_at, device_id,
        adjustment_sign, category, period_id, idempotency_key, reason, distributor_id, business_date
    ) VALUES (
        p_shop_id, v_log_id, v_wallet_id, v_entry_type, v_abs, v_before, v_after,
        'Classified: ' || p_category, p_staff_id, p_staff_name, v_now, COALESCE(p_device_id, 'DEV_UNSPECIFIED'),
        CASE WHEN p_amount_paise < 0 THEN -1 ELSE 1 END, p_category, v_pid, p_idempotency_key, p_reason,
        p_distributor_id, public.recharge_acc_ist_date(p_transaction_date)
    );

    IF p_category = 'topUpDistributorCredit' THEN
        UPDATE public.recharge_distributors
        SET outstanding_balance_paise = outstanding_balance_paise + v_abs
        WHERE shop_id = p_shop_id AND distributor_id = p_distributor_id;
        INSERT INTO public.recharge_distributor_ledger (
            shop_id, entry_id, distributor_id, wallet_id, amount_paise, entry_type,
            balance_before_paise, balance_after_paise, payment_mode, reference_id, notes, created_at,
            operator, idempotency_key, created_by
        ) VALUES (
            p_shop_id, v_log_id, p_distributor_id, v_wallet_id, v_abs, 'credit_extended',
            v_dist.outstanding_balance_paise, v_dist.outstanding_balance_paise + v_abs, 'credit_stock',
            v_log_id, p_reason, v_now, v_op, p_idempotency_key, p_staff_id
        );
    END IF;

    INSERT INTO public.recharge_audit_logs (shop_id, audit_id, event_type, actor_uid, device_id, entity_id, payload)
    VALUES (p_shop_id, gen_random_uuid()::text, 'ACC_CLASSIFIED_POSTING', p_staff_id, p_device_id, v_log_id,
        jsonb_build_object('operator', v_op, 'category', p_category, 'amount', p_amount_paise,
            'reason', p_reason, 'distributor', p_distributor_id, 'period', v_pid,
            'transaction_date', p_transaction_date));

    RETURN jsonb_build_object('success', true, 'replayed', false, 'reference_id', v_log_id, 'periodId', v_pid);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ----------------------------------------------------------------------------
-- 9. Night closing: verified snapshot, locks the period
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recharge_acc_verify_closing(
    p_shop_id TEXT, p_operator TEXT, p_actual_paise BIGINT, p_reason TEXT,
    p_idempotency_key TEXT, p_staff_id TEXT, p_device_id TEXT
) RETURNS JSONB AS $$
DECLARE
    v_op TEXT := lower(p_operator);
    v_existing public.recharge_period_snapshots;
    v_prev public.recharge_period_snapshots;
    v_pid TEXT;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_net BIGINT;
    v_pending BIGINT;
    v_expected BIGINT;
    v_variance BIGINT;
    v_status TEXT;
BEGIN
    PERFORM public.recharge_acc_validate(v_op, p_actual_paise, p_idempotency_key, false, true);
    PERFORM pg_advisory_xact_lock(hashtext('recharge_acc:' || p_shop_id || ':' || v_op));

    SELECT * INTO v_existing FROM public.recharge_period_snapshots
    WHERE shop_id = p_shop_id AND idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN jsonb_build_object('success', true, 'replayed', true, 'reference_id', v_existing.snapshot_id,
            'expectedPaise', v_existing.expected_paise, 'variancePaise', v_existing.variance_paise,
            'status', v_existing.status);
    END IF;

    v_prev := public.recharge_acc_last_closing(p_shop_id, v_op);
    IF v_prev.snapshot_id IS NULL THEN
        RAISE EXCEPTION 'PREVIOUS_CLOSING_MISSING: enter a verified reference balance first';
    END IF;
    v_pid := public.recharge_acc_period_id(v_op, v_prev.created_at);

    SELECT COALESCE(SUM(public.recharge_acc_signed(m.kind, m.amount_paise, m.pending)), 0),
           COALESCE(SUM(CASE WHEN m.pending THEN m.amount_paise ELSE 0 END), 0)
    INTO v_net, v_pending
    FROM public.recharge_acc_movements(p_shop_id, v_op, v_prev.created_at, v_now) m;

    v_expected := COALESCE(v_prev.actual_paise, 0) + v_net;
    v_variance := p_actual_paise - v_expected;
    v_status := CASE WHEN v_pending <> 0 THEN 'investigationRequired'
                     WHEN v_variance = 0 THEN 'match'
                     WHEN v_variance < 0 THEN 'shortage'
                     ELSE 'excess' END;
    IF v_variance <> 0 AND COALESCE(trim(p_reason), '') = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED: a reason is required when there is a variance';
    END IF;

    INSERT INTO public.recharge_period_snapshots (
        shop_id, snapshot_id, operator, kind, period_id, previous_closing_at, actual_paise,
        expected_paise, variance_paise, status, reason, business_date, idempotency_key, created_by, device_id, created_at
    ) VALUES (
        p_shop_id, 'CLOSE_' || v_pid, v_op, 'closing', v_pid, v_prev.created_at, p_actual_paise,
        v_expected, v_variance, v_status, p_reason, public.recharge_acc_ist_date(v_now),
        p_idempotency_key, p_staff_id, p_device_id, v_now
    );

    INSERT INTO public.recharge_audit_logs (shop_id, audit_id, event_type, actor_uid, device_id, entity_id, payload)
    VALUES (p_shop_id, gen_random_uuid()::text, 'ACC_CLOSING_VERIFY', p_staff_id, p_device_id, 'CLOSE_' || v_pid,
        jsonb_build_object('operator', v_op, 'expected', v_expected, 'actual', p_actual_paise,
            'variance', v_variance, 'status', v_status, 'reason', p_reason));

    RETURN jsonb_build_object('success', true, 'replayed', false, 'reference_id', 'CLOSE_' || v_pid,
        'periodId', v_pid, 'expectedPaise', v_expected, 'variancePaise', v_variance, 'status', v_status);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ----------------------------------------------------------------------------
-- 10. Settlement (read) per distributor and operator
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recharge_acc_settlement(p_shop_id TEXT)
RETURNS JSONB AS $$
    WITH rows AS (
        SELECT l.distributor_id,
               COALESCE(l.operator, lower(w.operator), 'unassigned') AS operator,
               CASE WHEN l.entry_type = 'credit_extended' THEN l.amount_paise ELSE 0 END AS payable,
               CASE WHEN l.entry_type = 'settlement_payment' THEN l.amount_paise ELSE 0 END AS paid,
               CASE WHEN l.entry_type = 'settlement_payment' THEN l.created_at END AS paid_at
        FROM public.recharge_distributor_ledger l
        LEFT JOIN public.recharge_wallets w ON w.shop_id = l.shop_id AND w.wallet_id = l.wallet_id
        WHERE l.shop_id = p_shop_id
        UNION ALL
        SELECT d.distributor_id, COALESCE(d.default_operator, 'unassigned'), d.legacy_opening_paise, 0, NULL
        FROM public.recharge_distributors d
        WHERE d.shop_id = p_shop_id AND d.legacy_opening_paise <> 0
    ), acc AS (
        SELECT r.distributor_id, r.operator, SUM(r.payable) AS payable, SUM(r.paid) AS paid, MAX(r.paid_at) AS last_paid
        FROM rows r GROUP BY r.distributor_id, r.operator
    )
    SELECT jsonb_build_object('success', true, 'accounts', COALESCE(jsonb_agg(jsonb_build_object(
        'distributor_id', a.distributor_id,
        'distributor_name', d.name,
        'operator', a.operator,
        'payable_paise', a.payable,
        'paid_paise', a.paid,
        'balance_paise', a.payable - a.paid,
        'last_payment_at', a.last_paid) ORDER BY d.name, a.operator), '[]'::jsonb))
    FROM acc a
    JOIN public.recharge_distributors d ON d.shop_id = p_shop_id AND d.distributor_id = a.distributor_id;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ----------------------------------------------------------------------------
-- 11. Operator-wise distributor payment (partial, full, advance), idempotent.
--     Never touches recharge transactions or wallet balances.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recharge_acc_distributor_payment(
    p_shop_id TEXT, p_distributor_id TEXT, p_operator TEXT, p_amount_paise BIGINT,
    p_payment_mode TEXT, p_payment_date TIMESTAMPTZ, p_reference_no TEXT, p_notes TEXT,
    p_idempotency_key TEXT, p_staff_id TEXT, p_device_id TEXT
) RETURNS JSONB AS $$
DECLARE
    v_op TEXT := lower(p_operator);
    v_dist RECORD;
    v_existing RECORD;
    v_before BIGINT;
    v_after BIGINT;
    v_mode TEXT;
    v_entry_id TEXT := 'PAY_' || p_idempotency_key;
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    PERFORM public.recharge_acc_validate(v_op, p_amount_paise, p_idempotency_key, false, false);
    IF p_payment_date IS NULL OR p_payment_date > v_now + interval '5 minutes' THEN
        RAISE EXCEPTION 'FUTURE_DATE: payment date cannot be in the future';
    END IF;
    v_mode := CASE lower(COALESCE(p_payment_mode, ''))
        WHEN 'cash' THEN 'cash' WHEN 'upi' THEN 'upi' WHEN 'cheque' THEN 'cheque'
        WHEN 'bank' THEN 'bank_transfer' WHEN 'bank transfer' THEN 'bank_transfer'
        WHEN 'bank_transfer' THEN 'bank_transfer' ELSE NULL END;
    IF v_mode IS NULL THEN RAISE EXCEPTION 'INVALID_PAYMENT_MODE: %', p_payment_mode; END IF;

    SELECT * INTO v_dist FROM public.recharge_distributors
    WHERE shop_id = p_shop_id AND distributor_id = p_distributor_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'UNKNOWN_DISTRIBUTOR: %', p_distributor_id; END IF;

    SELECT * INTO v_existing FROM public.recharge_distributor_ledger
    WHERE shop_id = p_shop_id AND idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN jsonb_build_object('success', true, 'replayed', true, 'reference_id', v_existing.entry_id,
            'balanceAfterPaise', v_existing.signed_balance_after_paise);
    END IF;

    SELECT COALESCE(SUM(CASE WHEN a->>'operator' = v_op THEN (a->>'balance_paise')::bigint ELSE 0 END), 0)
    INTO v_before
    FROM jsonb_array_elements(public.recharge_acc_settlement(p_shop_id)->'accounts') a
    WHERE a->>'distributor_id' = p_distributor_id;
    v_after := v_before - p_amount_paise;

    INSERT INTO public.recharge_distributor_ledger (
        shop_id, entry_id, distributor_id, wallet_id, amount_paise, entry_type,
        balance_before_paise, balance_after_paise, payment_mode, reference_id, notes, created_at,
        operator, idempotency_key, signed_balance_before_paise, signed_balance_after_paise,
        payment_date, reference_no, created_by
    ) VALUES (
        p_shop_id, v_entry_id, p_distributor_id, public.recharge_acc_wallet_id(v_op), p_amount_paise, 'settlement_payment',
        GREATEST(v_before, 0), GREATEST(v_after, 0), v_mode, v_entry_id, p_notes, v_now,
        v_op, p_idempotency_key, v_before, v_after,
        public.recharge_acc_ist_date(p_payment_date), NULLIF(trim(COALESCE(p_reference_no, '')), ''), p_staff_id
    );

    -- Legacy single-balance column kept consistent (never negative).
    UPDATE public.recharge_distributors
    SET outstanding_balance_paise = GREATEST(outstanding_balance_paise - p_amount_paise, 0)
    WHERE shop_id = p_shop_id AND distributor_id = p_distributor_id;

    INSERT INTO public.recharge_audit_logs (shop_id, audit_id, event_type, actor_uid, device_id, entity_id, payload)
    VALUES (p_shop_id, gen_random_uuid()::text, 'ACC_DISTRIBUTOR_PAYMENT', p_staff_id, p_device_id, v_entry_id,
        jsonb_build_object('distributor', p_distributor_id, 'operator', v_op, 'amount', p_amount_paise,
            'mode', v_mode, 'reference_no', p_reference_no, 'before', v_before, 'after', v_after));

    RETURN jsonb_build_object('success', true, 'replayed', false, 'reference_id', v_entry_id,
        'balanceBeforePaise', v_before, 'balanceAfterPaise', v_after,
        'outstandingPaise', GREATEST(v_after, 0), 'advancePaise', GREATEST(-v_after, 0));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ----------------------------------------------------------------------------
-- 12. Execution rights: only the Edge Function (service role) may call these.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    fn TEXT;
BEGIN
    FOREACH fn IN ARRAY ARRAY[
        'recharge_acc_period_state(text)',
        'recharge_acc_verify_morning(text,text,bigint,text,text,text)',
        'recharge_acc_reference_balance(text,text,bigint,text,text,text,text)',
        'recharge_acc_post_classified(text,text,text,bigint,text,timestamptz,text,text,text,text,text)',
        'recharge_acc_verify_closing(text,text,bigint,text,text,text,text)',
        'recharge_acc_settlement(text)',
        'recharge_acc_distributor_payment(text,text,text,bigint,text,timestamptz,text,text,text,text,text)'
    ] LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon, authenticated;', fn);
        EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO service_role;', fn);
    END LOOP;
END $$;
