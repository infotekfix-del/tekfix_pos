-- ============================================================================
-- TEKFIX ERP - QUICK RECHARGE v2.1: LEGACY FLOWS MADE SERVER-AUTHORITATIVE
--   * Operator Agent Settlement (with recharge adjustment)
--   * Recharge Amount Return from agent
--   * Distributor credit reversal
--   * Customer refund
--   * Failed-recharge wallet reversal
--   * Commission reversal
-- ADDITIVE ONLY: new table, new nullable columns, new procedures. No existing
-- row is deleted, no column dropped, no existing CHECK removed. Integer paise.
-- recharge_acc_settlement is REPLACED (same signature) so that credit
-- reversals and pending agent returns are included; its old fields remain.
-- NOT TESTED: no Docker / Supabase CLI on the build machine.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Immutable event ledger for the flows above
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.recharge_acc_events (
    shop_id TEXT NOT NULL,
    event_id TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN (
        'agent_adjustment', 'agent_return', 'credit_reversal',
        'customer_refund', 'failed_reversal', 'commission_reversal')),
    distributor_id TEXT,
    operator TEXT NOT NULL CHECK (operator IN ('airtel', 'jio', 'vi', 'bsnl')),
    txn_key TEXT,
    amount_paise BIGINT NOT NULL CHECK (amount_paise >= 0),
    cash_bank_paise BIGINT NOT NULL DEFAULT 0, -- + money in, - money out
    payment_mode TEXT,
    reason TEXT,
    reference_no TEXT,
    business_date DATE NOT NULL,
    idempotency_key TEXT NOT NULL,
    created_by TEXT NOT NULL,
    device_id TEXT,
    payload JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (shop_id, event_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_acc_events_idempotency
ON public.recharge_acc_events (shop_id, idempotency_key);

-- One refund / one failure reversal / one commission reversal per recharge.
CREATE UNIQUE INDEX IF NOT EXISTS idx_acc_events_once_per_txn
ON public.recharge_acc_events (shop_id, kind, txn_key)
WHERE kind IN ('customer_refund', 'failed_reversal', 'commission_reversal');

CREATE INDEX IF NOT EXISTS idx_acc_events_distributor
ON public.recharge_acc_events (shop_id, distributor_id, operator)
WHERE distributor_id IS NOT NULL;

ALTER TABLE public.recharge_acc_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Deny direct public client access" ON public.recharge_acc_events;
CREATE POLICY "Deny direct public client access" ON public.recharge_acc_events
    FOR ALL TO anon, authenticated USING (false);

DROP TRIGGER IF EXISTS trg_prevent_acc_events_tampering ON public.recharge_acc_events;
CREATE TRIGGER trg_prevent_acc_events_tampering
BEFORE UPDATE OR DELETE ON public.recharge_acc_events
FOR EACH ROW EXECUTE FUNCTION public.recharge_prevent_ledger_tampering();

-- Split of an agent settlement row (NULL on all other rows).
ALTER TABLE public.recharge_distributor_ledger
    ADD COLUMN IF NOT EXISTS actual_payment_paise BIGINT,
    ADD COLUMN IF NOT EXISTS recharge_adjustment_paise BIGINT;

-- ----------------------------------------------------------------------------
-- 2. Helpers
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recharge_acc_payment_mode(p_mode TEXT)
RETURNS TEXT AS $$
    SELECT CASE lower(trim(COALESCE(p_mode, '')))
        WHEN 'cash' THEN 'cash' WHEN 'upi' THEN 'upi' WHEN 'cheque' THEN 'cheque'
        WHEN 'bank' THEN 'bank_transfer' WHEN 'bank transfer' THEN 'bank_transfer'
        WHEN 'bank_transfer' THEN 'bank_transfer' ELSE NULL END;
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION public.recharge_acc_require_key_reason(
    p_idempotency_key TEXT, p_reason TEXT, p_reason_required BOOLEAN
) RETURNS VOID AS $$
BEGIN
    IF p_idempotency_key IS NULL OR p_idempotency_key !~ '^[A-Za-z0-9_\-:.]{8,120}$' THEN
        RAISE EXCEPTION 'INVALID_KEY';
    END IF;
    IF p_reason_required AND COALESCE(trim(p_reason), '') = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Pending recharge-adjustment return of one distributor x operator.
CREATE OR REPLACE FUNCTION public.recharge_acc_pending_return(
    p_shop_id TEXT, p_distributor_id TEXT, p_operator TEXT
) RETURNS BIGINT AS $$
    SELECT COALESCE(SUM(CASE kind WHEN 'agent_adjustment' THEN amount_paise ELSE -amount_paise END), 0)
    FROM public.recharge_acc_events
    WHERE shop_id = p_shop_id AND distributor_id = p_distributor_id
      AND operator = lower(p_operator) AND kind IN ('agent_adjustment', 'agent_return');
$$ LANGUAGE sql STABLE;

-- ----------------------------------------------------------------------------
-- 3. Settlement read (REPLACES v2): payable now also minus credit reversals;
--    adds pending_return_paise. Fields of v2 are unchanged.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recharge_acc_settlement(p_shop_id TEXT)
RETURNS JSONB AS $$
    WITH rows AS (
        SELECT l.distributor_id,
               COALESCE(l.operator, lower(w.operator), 'unassigned') AS operator,
               CASE WHEN l.entry_type = 'credit_extended' THEN l.amount_paise ELSE 0 END AS payable,
               CASE WHEN l.entry_type = 'settlement_payment' THEN l.amount_paise ELSE 0 END AS paid,
               CASE WHEN l.entry_type = 'settlement_payment' THEN l.created_at END AS paid_at,
               0::bigint AS pending_return
        FROM public.recharge_distributor_ledger l
        LEFT JOIN public.recharge_wallets w ON w.shop_id = l.shop_id AND w.wallet_id = l.wallet_id
        WHERE l.shop_id = p_shop_id
        UNION ALL
        SELECT d.distributor_id, COALESCE(d.default_operator, 'unassigned'), d.legacy_opening_paise, 0, NULL, 0
        FROM public.recharge_distributors d
        WHERE d.shop_id = p_shop_id AND d.legacy_opening_paise <> 0
        UNION ALL
        SELECT e.distributor_id, e.operator,
               CASE WHEN e.kind = 'credit_reversal' THEN -e.amount_paise ELSE 0 END,
               0, NULL,
               CASE e.kind WHEN 'agent_adjustment' THEN e.amount_paise
                           WHEN 'agent_return' THEN -e.amount_paise ELSE 0 END
        FROM public.recharge_acc_events e
        WHERE e.shop_id = p_shop_id AND e.distributor_id IS NOT NULL
          AND e.kind IN ('credit_reversal', 'agent_adjustment', 'agent_return')
    ), acc AS (
        SELECT r.distributor_id, r.operator, SUM(r.payable) AS payable, SUM(r.paid) AS paid,
               MAX(r.paid_at) AS last_paid, SUM(r.pending_return) AS pending_return
        FROM rows r GROUP BY r.distributor_id, r.operator
    )
    SELECT jsonb_build_object('success', true, 'accounts', COALESCE(jsonb_agg(jsonb_build_object(
        'distributor_id', a.distributor_id,
        'distributor_name', d.name,
        'operator', a.operator,
        'payable_paise', a.payable,
        'paid_paise', a.paid,
        'balance_paise', a.payable - a.paid,
        'pending_return_paise', a.pending_return,
        'last_payment_at', a.last_paid) ORDER BY d.name, a.operator), '[]'::jsonb))
    FROM acc a
    JOIN public.recharge_distributors d ON d.shop_id = p_shop_id AND d.distributor_id = a.distributor_id;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Balance / payable of one account, from the read above.
CREATE OR REPLACE FUNCTION public.recharge_acc_account_field(
    p_shop_id TEXT, p_distributor_id TEXT, p_operator TEXT, p_field TEXT
) RETURNS BIGINT AS $$
    SELECT COALESCE(SUM((a->>p_field)::bigint), 0)
    FROM jsonb_array_elements(public.recharge_acc_settlement(p_shop_id)->'accounts') a
    WHERE a->>'distributor_id' = p_distributor_id AND a->>'operator' = lower(p_operator);
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION public.recharge_acc_agent_returns(p_shop_id TEXT)
RETURNS JSONB AS $$
    SELECT jsonb_build_object('success', true, 'accounts', COALESCE(jsonb_agg(jsonb_build_object(
        'distributor_id', x.distributor_id, 'operator', x.operator,
        'pending_return_paise', x.pending)), '[]'::jsonb))
    FROM (
        SELECT distributor_id, operator,
               SUM(CASE kind WHEN 'agent_adjustment' THEN amount_paise ELSE -amount_paise END) AS pending
        FROM public.recharge_acc_events
        WHERE shop_id = p_shop_id AND kind IN ('agent_adjustment', 'agent_return')
        GROUP BY distributor_id, operator
    ) x;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ----------------------------------------------------------------------------
-- 4. Operator Agent Settlement. Payable reduced by the TOTAL; only
--    total - adjustment leaves cash/bank; adjustment becomes a pending return.
--    Never touches recharge transactions or wallets (cumulative unchanged).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recharge_acc_agent_settlement(
    p_shop_id TEXT, p_distributor_id TEXT, p_operator TEXT,
    p_total_paise BIGINT, p_adjustment_paise BIGINT,
    p_payment_mode TEXT, p_payment_date TIMESTAMPTZ, p_reference_no TEXT, p_notes TEXT,
    p_idempotency_key TEXT, p_staff_id TEXT, p_device_id TEXT
) RETURNS JSONB AS $$
DECLARE
    v_op TEXT := lower(p_operator);
    v_mode TEXT := public.recharge_acc_payment_mode(p_payment_mode);
    v_existing RECORD;
    v_before BIGINT;
    v_after BIGINT;
    v_actual BIGINT;
    v_pending BIGINT;
    v_entry_id TEXT := 'SETTLE_' || p_idempotency_key;
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    PERFORM public.recharge_acc_validate(v_op, p_total_paise, p_idempotency_key, false, false);
    PERFORM public.recharge_acc_validate(v_op, p_adjustment_paise, p_idempotency_key, false, true);
    IF p_adjustment_paise > p_total_paise THEN
        RAISE EXCEPTION 'ADJUSTMENT_EXCEEDS_TOTAL: adjustment cannot exceed total payable';
    END IF;
    IF v_mode IS NULL THEN RAISE EXCEPTION 'INVALID_PAYMENT_MODE: %', p_payment_mode; END IF;
    IF p_payment_date IS NULL OR p_payment_date > v_now + interval '5 minutes' THEN
        RAISE EXCEPTION 'FUTURE_DATE: payment date cannot be in the future';
    END IF;

    PERFORM 1 FROM public.recharge_distributors
    WHERE shop_id = p_shop_id AND distributor_id = p_distributor_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'UNKNOWN_DISTRIBUTOR: %', p_distributor_id; END IF;

    SELECT * INTO v_existing FROM public.recharge_distributor_ledger
    WHERE shop_id = p_shop_id AND idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN jsonb_build_object('success', true, 'replayed', true, 'reference_id', v_existing.entry_id,
            'balanceAfterPaise', v_existing.signed_balance_after_paise,
            'actualPaymentPaise', v_existing.actual_payment_paise,
            'pendingReturnPaise', public.recharge_acc_pending_return(p_shop_id, p_distributor_id, v_op));
    END IF;

    v_before := public.recharge_acc_account_field(p_shop_id, p_distributor_id, v_op, 'balance_paise');
    v_after := v_before - p_total_paise;
    v_actual := p_total_paise - p_adjustment_paise;

    INSERT INTO public.recharge_distributor_ledger (
        shop_id, entry_id, distributor_id, wallet_id, amount_paise, entry_type,
        balance_before_paise, balance_after_paise, payment_mode, reference_id, notes, created_at,
        operator, idempotency_key, signed_balance_before_paise, signed_balance_after_paise,
        payment_date, reference_no, created_by, actual_payment_paise, recharge_adjustment_paise
    ) VALUES (
        p_shop_id, v_entry_id, p_distributor_id, public.recharge_acc_wallet_id(v_op), p_total_paise, 'settlement_payment',
        GREATEST(v_before, 0), GREATEST(v_after, 0), v_mode, v_entry_id,
        COALESCE(p_notes, '') || ' [AGENT_SETTLEMENT]', v_now,
        v_op, p_idempotency_key, v_before, v_after,
        public.recharge_acc_ist_date(p_payment_date), NULLIF(trim(COALESCE(p_reference_no, '')), ''), p_staff_id,
        v_actual, p_adjustment_paise
    );

    IF p_adjustment_paise > 0 THEN
        INSERT INTO public.recharge_acc_events (
            shop_id, event_id, kind, distributor_id, operator, amount_paise, cash_bank_paise,
            payment_mode, reason, reference_no, business_date, idempotency_key, created_by, device_id, payload
        ) VALUES (
            p_shop_id, 'ADJ_' || p_idempotency_key, 'agent_adjustment', p_distributor_id, v_op,
            p_adjustment_paise, 0, v_mode, p_notes, NULLIF(trim(COALESCE(p_reference_no, '')), ''),
            public.recharge_acc_ist_date(p_payment_date), p_idempotency_key || ':ADJ', p_staff_id, p_device_id,
            jsonb_build_object('settlement_entry', v_entry_id)
        );
    END IF;

    UPDATE public.recharge_distributors
    SET outstanding_balance_paise = GREATEST(outstanding_balance_paise - p_total_paise, 0)
    WHERE shop_id = p_shop_id AND distributor_id = p_distributor_id;

    v_pending := public.recharge_acc_pending_return(p_shop_id, p_distributor_id, v_op);

    INSERT INTO public.recharge_audit_logs (shop_id, audit_id, event_type, actor_uid, device_id, entity_id, payload)
    VALUES (p_shop_id, gen_random_uuid()::text, 'ACC_AGENT_SETTLEMENT', p_staff_id, p_device_id, v_entry_id,
        jsonb_build_object('distributor', p_distributor_id, 'operator', v_op, 'total', p_total_paise,
            'adjustment', p_adjustment_paise, 'actual', v_actual, 'mode', v_mode,
            'reference_no', p_reference_no, 'before', v_before, 'after', v_after, 'pending_return', v_pending));

    RETURN jsonb_build_object('success', true, 'replayed', false, 'reference_id', v_entry_id,
        'balanceBeforePaise', v_before, 'balanceAfterPaise', v_after,
        'outstandingPaise', GREATEST(v_after, 0), 'advancePaise', GREATEST(-v_after, 0),
        'actualPaymentPaise', v_actual, 'pendingReturnPaise', v_pending);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ----------------------------------------------------------------------------
-- 5. Recharge Amount Return from agent (<= pending return of that account)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recharge_acc_agent_return(
    p_shop_id TEXT, p_distributor_id TEXT, p_operator TEXT, p_return_paise BIGINT,
    p_return_mode TEXT, p_return_date TIMESTAMPTZ, p_reference_no TEXT, p_notes TEXT,
    p_idempotency_key TEXT, p_staff_id TEXT, p_device_id TEXT
) RETURNS JSONB AS $$
DECLARE
    v_op TEXT := lower(p_operator);
    v_mode TEXT := public.recharge_acc_payment_mode(p_return_mode);
    v_pending BIGINT;
    v_event_id TEXT := 'RET_' || p_idempotency_key;
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    PERFORM public.recharge_acc_validate(v_op, p_return_paise, p_idempotency_key, false, false);
    IF v_mode IS NULL THEN RAISE EXCEPTION 'INVALID_PAYMENT_MODE: %', p_return_mode; END IF;
    IF p_return_date IS NULL OR p_return_date > v_now + interval '5 minutes' THEN
        RAISE EXCEPTION 'FUTURE_DATE: return date cannot be in the future';
    END IF;

    PERFORM 1 FROM public.recharge_distributors
    WHERE shop_id = p_shop_id AND distributor_id = p_distributor_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'UNKNOWN_DISTRIBUTOR: %', p_distributor_id; END IF;

    IF EXISTS (SELECT 1 FROM public.recharge_acc_events WHERE shop_id = p_shop_id AND idempotency_key = p_idempotency_key) THEN
        RETURN jsonb_build_object('success', true, 'replayed', true, 'reference_id', v_event_id,
            'pendingReturnPaise', public.recharge_acc_pending_return(p_shop_id, p_distributor_id, v_op));
    END IF;

    v_pending := public.recharge_acc_pending_return(p_shop_id, p_distributor_id, v_op);
    IF p_return_paise > v_pending THEN
        RAISE EXCEPTION 'EXCEEDS_PENDING_RETURN: pending return is % paise', v_pending;
    END IF;

    INSERT INTO public.recharge_acc_events (
        shop_id, event_id, kind, distributor_id, operator, amount_paise, cash_bank_paise,
        payment_mode, reason, reference_no, business_date, idempotency_key, created_by, device_id
    ) VALUES (
        p_shop_id, v_event_id, 'agent_return', p_distributor_id, v_op, p_return_paise, p_return_paise,
        v_mode, p_notes, NULLIF(trim(COALESCE(p_reference_no, '')), ''),
        public.recharge_acc_ist_date(p_return_date), p_idempotency_key, p_staff_id, p_device_id
    );

    INSERT INTO public.recharge_audit_logs (shop_id, audit_id, event_type, actor_uid, device_id, entity_id, payload)
    VALUES (p_shop_id, gen_random_uuid()::text, 'ACC_AGENT_RETURN', p_staff_id, p_device_id, v_event_id,
        jsonb_build_object('distributor', p_distributor_id, 'operator', v_op, 'amount', p_return_paise,
            'mode', v_mode, 'pending_before', v_pending, 'pending_after', v_pending - p_return_paise));

    RETURN jsonb_build_object('success', true, 'replayed', false, 'reference_id', v_event_id,
        'pendingBeforePaise', v_pending, 'pendingReturnPaise', v_pending - p_return_paise);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ----------------------------------------------------------------------------
-- 6. Distributor credit reversal (<= credit payable of that account)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recharge_acc_credit_reversal(
    p_shop_id TEXT, p_distributor_id TEXT, p_operator TEXT, p_amount_paise BIGINT, p_reason TEXT,
    p_idempotency_key TEXT, p_staff_id TEXT, p_device_id TEXT
) RETURNS JSONB AS $$
DECLARE
    v_op TEXT := lower(p_operator);
    v_payable BIGINT;
    v_before BIGINT;
    v_event_id TEXT := 'DREV_' || p_idempotency_key;
BEGIN
    PERFORM public.recharge_acc_validate(v_op, p_amount_paise, p_idempotency_key, false, false);
    PERFORM public.recharge_acc_require_key_reason(p_idempotency_key, p_reason, true);

    PERFORM 1 FROM public.recharge_distributors
    WHERE shop_id = p_shop_id AND distributor_id = p_distributor_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'UNKNOWN_DISTRIBUTOR: %', p_distributor_id; END IF;

    IF EXISTS (SELECT 1 FROM public.recharge_acc_events WHERE shop_id = p_shop_id AND idempotency_key = p_idempotency_key) THEN
        RETURN jsonb_build_object('success', true, 'replayed', true, 'reference_id', v_event_id);
    END IF;

    v_payable := public.recharge_acc_account_field(p_shop_id, p_distributor_id, v_op, 'payable_paise');
    IF p_amount_paise > v_payable THEN
        RAISE EXCEPTION 'EXCEEDS_PAYABLE: credit payable is % paise', v_payable;
    END IF;
    v_before := public.recharge_acc_account_field(p_shop_id, p_distributor_id, v_op, 'balance_paise');

    INSERT INTO public.recharge_acc_events (
        shop_id, event_id, kind, distributor_id, operator, amount_paise, reason,
        business_date, idempotency_key, created_by, device_id
    ) VALUES (
        p_shop_id, v_event_id, 'credit_reversal', p_distributor_id, v_op, p_amount_paise, p_reason,
        public.recharge_acc_ist_date(clock_timestamp()), p_idempotency_key, p_staff_id, p_device_id
    );

    UPDATE public.recharge_distributors
    SET outstanding_balance_paise = GREATEST(outstanding_balance_paise - p_amount_paise, 0)
    WHERE shop_id = p_shop_id AND distributor_id = p_distributor_id;

    INSERT INTO public.recharge_audit_logs (shop_id, audit_id, event_type, actor_uid, device_id, entity_id, payload)
    VALUES (p_shop_id, gen_random_uuid()::text, 'ACC_CREDIT_REVERSAL', p_staff_id, p_device_id, v_event_id,
        jsonb_build_object('distributor', p_distributor_id, 'operator', v_op, 'amount', p_amount_paise,
            'reason', p_reason, 'before', v_before, 'after', v_before - p_amount_paise));

    RETURN jsonb_build_object('success', true, 'replayed', false, 'reference_id', v_event_id,
        'balanceBeforePaise', v_before, 'balanceAfterPaise', v_before - p_amount_paise);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ----------------------------------------------------------------------------
-- 7. Customer refund: once per recharge, <= face value, no wallet change.
--    The recharge stays in cumulative volume; the refund is its own event.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recharge_acc_customer_refund(
    p_shop_id TEXT, p_txn_key TEXT, p_refund_paise BIGINT, p_refund_method TEXT, p_reason TEXT,
    p_idempotency_key TEXT, p_staff_id TEXT, p_device_id TEXT
) RETURNS JSONB AS $$
DECLARE
    v_txn RECORD;
    v_method TEXT := lower(trim(COALESCE(p_refund_method, '')));
    v_event_id TEXT := 'REFUND_' || p_idempotency_key;
BEGIN
    PERFORM public.recharge_acc_require_key_reason(p_idempotency_key, p_reason, true);
    IF p_refund_paise IS NULL OR p_refund_paise <= 0 OR p_refund_paise > 100000000 THEN
        RAISE EXCEPTION 'INVALID_AMOUNT: refund must be positive and within Rs 10,00,000';
    END IF;
    IF v_method NOT IN ('cash', 'upi', 'card', 'bank') THEN
        RAISE EXCEPTION 'INVALID_REFUND_METHOD: %', p_refund_method;
    END IF;

    SELECT * INTO v_txn FROM public.recharge_transactions
    WHERE shop_id = p_shop_id AND txn_key = p_txn_key FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'UNKNOWN_RECHARGE: %', p_txn_key; END IF;

    IF EXISTS (SELECT 1 FROM public.recharge_acc_events WHERE shop_id = p_shop_id AND idempotency_key = p_idempotency_key) THEN
        RETURN jsonb_build_object('success', true, 'replayed', true, 'reference_id', v_event_id, 'status', 'refunded');
    END IF;
    IF v_txn.status IN ('refunded', 'reversed') OR EXISTS (
        SELECT 1 FROM public.recharge_acc_events
        WHERE shop_id = p_shop_id AND kind = 'customer_refund' AND txn_key = p_txn_key) THEN
        RAISE EXCEPTION 'ALREADY_REFUNDED: %', p_txn_key;
    END IF;
    IF p_refund_paise > v_txn.amount_paise THEN
        RAISE EXCEPTION 'EXCEEDS_RECHARGE: refund % is more than recharge %', p_refund_paise, v_txn.amount_paise;
    END IF;

    INSERT INTO public.recharge_acc_events (
        shop_id, event_id, kind, operator, txn_key, amount_paise, cash_bank_paise, payment_mode, reason,
        business_date, idempotency_key, created_by, device_id
    ) VALUES (
        p_shop_id, v_event_id, 'customer_refund', lower(v_txn.operator), p_txn_key, p_refund_paise,
        -p_refund_paise, v_method, p_reason, public.recharge_acc_ist_date(clock_timestamp()),
        p_idempotency_key, p_staff_id, p_device_id
    );

    UPDATE public.recharge_transactions SET status = 'refunded'
    WHERE shop_id = p_shop_id AND txn_key = p_txn_key;

    INSERT INTO public.recharge_audit_logs (shop_id, audit_id, event_type, actor_uid, device_id, entity_id, payload)
    VALUES (p_shop_id, gen_random_uuid()::text, 'ACC_CUSTOMER_REFUND', p_staff_id, p_device_id, v_event_id,
        jsonb_build_object('txn', p_txn_key, 'operator', lower(v_txn.operator), 'amount', p_refund_paise,
            'method', v_method, 'reason', p_reason, 'previous_status', v_txn.status));

    RETURN jsonb_build_object('success', true, 'replayed', false, 'reference_id', v_event_id,
        'rechargeId', p_txn_key, 'refundPaise', p_refund_paise, 'refundMethod', v_method, 'status', 'refunded');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ----------------------------------------------------------------------------
-- 8. Failed-recharge reversal: status -> failed; a debited wallet is
--    credited back once. A success/refunded recharge is refused.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recharge_acc_failed_reversal(
    p_shop_id TEXT, p_txn_key TEXT, p_reason TEXT,
    p_idempotency_key TEXT, p_staff_id TEXT, p_device_id TEXT
) RETURNS JSONB AS $$
DECLARE
    v_txn RECORD;
    v_wallet RECORD;
    v_before BIGINT;
    v_credit BIGINT := 0;
    v_event_id TEXT := 'FAILREV_' || p_txn_key;
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    PERFORM public.recharge_acc_require_key_reason(p_idempotency_key, p_reason, true);

    SELECT * INTO v_txn FROM public.recharge_transactions
    WHERE shop_id = p_shop_id AND txn_key = p_txn_key FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'UNKNOWN_RECHARGE: %', p_txn_key; END IF;

    IF v_txn.status = 'failed' OR EXISTS (
        SELECT 1 FROM public.recharge_acc_events
        WHERE shop_id = p_shop_id AND kind = 'failed_reversal' AND txn_key = p_txn_key) THEN
        RETURN jsonb_build_object('success', true, 'replayed', true, 'reference_id', v_event_id,
            'alreadyFailed', true, 'walletCreditPaise', 0, 'status', 'failed');
    END IF;
    IF v_txn.status NOT IN ('pending', 'completed') THEN
        RAISE EXCEPTION 'INVALID_STATUS: a % recharge cannot be marked failed', v_txn.status;
    END IF;

    IF v_txn.wallet_debited THEN
        SELECT * INTO v_wallet FROM public.recharge_wallets
        WHERE shop_id = p_shop_id AND wallet_id = v_txn.wallet_id FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Wallet % not found', v_txn.wallet_id; END IF;
        v_before := v_wallet.total_balance_paise;
        v_credit := v_txn.amount_paise;
        IF v_txn.funding_type = 'distributorCredit' THEN
            UPDATE public.recharge_wallets
            SET distributor_credit_balance_paise = distributor_credit_balance_paise + v_credit, last_updated_at = v_now
            WHERE shop_id = p_shop_id AND wallet_id = v_txn.wallet_id;
        ELSE
            UPDATE public.recharge_wallets
            SET own_prepaid_balance_paise = own_prepaid_balance_paise + v_credit, last_updated_at = v_now
            WHERE shop_id = p_shop_id AND wallet_id = v_txn.wallet_id;
        END IF;
        -- category stays NULL: this is not a morning classification.
        INSERT INTO public.recharge_wallet_logs (
            shop_id, log_id, wallet_id, txn_key, entry_type, amount_paise,
            balance_before_paise, balance_after_paise, description, staff_id, created_at, device_id,
            idempotency_key, reason, business_date
        ) VALUES (
            p_shop_id, v_event_id, v_txn.wallet_id, p_txn_key, 'reversal', v_credit,
            v_before, v_before + v_credit, 'Failed recharge reversal: ' || p_reason, p_staff_id, v_now,
            COALESCE(p_device_id, 'DEV_UNSPECIFIED'), p_idempotency_key, p_reason,
            public.recharge_acc_ist_date(v_now)
        );
    END IF;

    UPDATE public.recharge_transactions SET status = 'failed'
    WHERE shop_id = p_shop_id AND txn_key = p_txn_key;

    INSERT INTO public.recharge_acc_events (
        shop_id, event_id, kind, operator, txn_key, amount_paise, reason,
        business_date, idempotency_key, created_by, device_id
    ) VALUES (
        p_shop_id, v_event_id, 'failed_reversal', lower(v_txn.operator), p_txn_key, v_credit, p_reason,
        public.recharge_acc_ist_date(v_now), p_idempotency_key, p_staff_id, p_device_id
    );

    INSERT INTO public.recharge_audit_logs (shop_id, audit_id, event_type, actor_uid, device_id, entity_id, payload)
    VALUES (p_shop_id, gen_random_uuid()::text, 'ACC_FAILED_REVERSAL', p_staff_id, p_device_id, v_event_id,
        jsonb_build_object('txn', p_txn_key, 'wallet_credit', v_credit, 'previous_status', v_txn.status,
            'reason', p_reason));

    RETURN jsonb_build_object('success', true, 'replayed', false, 'reference_id', v_event_id,
        'alreadyFailed', false, 'walletCreditPaise', v_credit, 'status', 'failed');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ----------------------------------------------------------------------------
-- 9. Commission reversal: amount from the server commission row; optional
--    clawback from the own-money wallet (never below zero). Once per recharge.
--    recharge_commissions rows are NOT modified (the event is the record).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recharge_acc_commission_reversal(
    p_shop_id TEXT, p_txn_key TEXT, p_clawback BOOLEAN, p_reason TEXT,
    p_idempotency_key TEXT, p_staff_id TEXT, p_device_id TEXT
) RETURNS JSONB AS $$
DECLARE
    v_txn RECORD;
    v_comm BIGINT;
    v_wallet RECORD;
    v_claw BIGINT := 0;
    v_event_id TEXT := 'COMMREV_' || p_txn_key;
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    PERFORM public.recharge_acc_require_key_reason(p_idempotency_key, p_reason, true);

    SELECT * INTO v_txn FROM public.recharge_transactions
    WHERE shop_id = p_shop_id AND txn_key = p_txn_key FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'UNKNOWN_RECHARGE: %', p_txn_key; END IF;

    IF EXISTS (SELECT 1 FROM public.recharge_acc_events WHERE shop_id = p_shop_id AND idempotency_key = p_idempotency_key) THEN
        RETURN jsonb_build_object('success', true, 'replayed', true, 'reference_id', v_event_id);
    END IF;
    IF EXISTS (SELECT 1 FROM public.recharge_acc_events
               WHERE shop_id = p_shop_id AND kind = 'commission_reversal' AND txn_key = p_txn_key) THEN
        RAISE EXCEPTION 'ALREADY_REVERSED: %', p_txn_key;
    END IF;

    SELECT COALESCE(SUM(commission_paise), 0) INTO v_comm FROM public.recharge_commissions
    WHERE shop_id = p_shop_id AND txn_key = p_txn_key;
    IF v_comm <= 0 THEN RAISE EXCEPTION 'UNKNOWN_COMMISSION: %', p_txn_key; END IF;

    IF p_clawback THEN
        SELECT * INTO v_wallet FROM public.recharge_wallets
        WHERE shop_id = p_shop_id AND wallet_id = v_txn.wallet_id FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Wallet % not found', v_txn.wallet_id; END IF;
        v_claw := LEAST(v_comm, v_wallet.own_prepaid_balance_paise);
        IF v_claw > 0 THEN
            UPDATE public.recharge_wallets
            SET own_prepaid_balance_paise = own_prepaid_balance_paise - v_claw, last_updated_at = v_now
            WHERE shop_id = p_shop_id AND wallet_id = v_txn.wallet_id;
            INSERT INTO public.recharge_wallet_logs (
                shop_id, log_id, wallet_id, txn_key, entry_type, amount_paise,
                balance_before_paise, balance_after_paise, description, staff_id, created_at, device_id,
                adjustment_sign, idempotency_key, reason, business_date
            ) VALUES (
                p_shop_id, v_event_id, v_txn.wallet_id, p_txn_key, 'adjustment', v_claw,
                v_wallet.total_balance_paise, v_wallet.total_balance_paise - v_claw,
                'Commission reversal clawback: ' || p_reason, p_staff_id, v_now,
                COALESCE(p_device_id, 'DEV_UNSPECIFIED'), -1, p_idempotency_key, p_reason,
                public.recharge_acc_ist_date(v_now)
            );
        END IF;
    END IF;

    INSERT INTO public.recharge_acc_events (
        shop_id, event_id, kind, operator, txn_key, amount_paise, reason,
        business_date, idempotency_key, created_by, device_id, payload
    ) VALUES (
        p_shop_id, v_event_id, 'commission_reversal', lower(v_txn.operator), p_txn_key, v_comm, p_reason,
        public.recharge_acc_ist_date(v_now), p_idempotency_key, p_staff_id, p_device_id,
        jsonb_build_object('wallet_clawback_paise', v_claw)
    );

    INSERT INTO public.recharge_audit_logs (shop_id, audit_id, event_type, actor_uid, device_id, entity_id, payload)
    VALUES (p_shop_id, gen_random_uuid()::text, 'ACC_COMMISSION_REVERSAL', p_staff_id, p_device_id, v_event_id,
        jsonb_build_object('txn', p_txn_key, 'commission', v_comm, 'clawback', v_claw, 'reason', p_reason));

    RETURN jsonb_build_object('success', true, 'replayed', false, 'reference_id', v_event_id,
        'commissionPaise', v_comm, 'walletClawbackPaise', v_claw);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ----------------------------------------------------------------------------
-- 10. Execution rights: only the Edge Function (service role).
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    fn TEXT;
BEGIN
    FOREACH fn IN ARRAY ARRAY[
        'recharge_acc_settlement(text)',
        'recharge_acc_agent_returns(text)',
        'recharge_acc_account_field(text,text,text,text)',
        'recharge_acc_pending_return(text,text,text)',
        'recharge_acc_agent_settlement(text,text,text,bigint,bigint,text,timestamptz,text,text,text,text,text)',
        'recharge_acc_agent_return(text,text,text,bigint,text,timestamptz,text,text,text,text,text)',
        'recharge_acc_credit_reversal(text,text,text,bigint,text,text,text,text)',
        'recharge_acc_customer_refund(text,text,bigint,text,text,text,text,text)',
        'recharge_acc_failed_reversal(text,text,text,text,text,text)',
        'recharge_acc_commission_reversal(text,text,boolean,text,text,text,text)'
    ] LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon, authenticated;', fn);
        EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO service_role;', fn);
    END LOOP;
END $$;
