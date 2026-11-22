-- ============================================================================
-- QUICK RECHARGE: OWNER CORRECTIONS OF SAVED RECHARGE ENTRIES (2026-11-22)
-- Owner rule: a saved recharge is never overwritten. Two server procedures:
--   * recharge_acc_correct_recharge: wrong amount / operator. The original is
--     marked 'reversed' (corrected), its wallet debit is credited back and its
--     commission is reversed (no wallet clawback). The client then saves the
--     right recharge through the normal recharge flow. Once per recharge.
--   * recharge_acc_edit_recharge: wrong mobile number or Cash <-> UPI. No
--     wallet movement; old and new values are kept in the event payload.
-- Both: owner only (edge function), reason + idempotency key required, and
-- refused once that operator's closing after the recharge is verified
-- (LOCKED_PERIOD). Additive. NOT TESTED (no Supabase CLI here).
-- ============================================================================

-- 1. New event kinds (the kind CHECK is replaced with a wider one).
DO $$
DECLARE c TEXT;
BEGIN
    FOR c IN
        SELECT conname FROM pg_constraint
        WHERE conrelid = 'public.recharge_acc_events'::regclass AND contype = 'c'
          AND pg_get_constraintdef(oid) LIKE '%kind%'
    LOOP
        EXECUTE format('ALTER TABLE public.recharge_acc_events DROP CONSTRAINT %I', c);
    END LOOP;
END $$;

ALTER TABLE public.recharge_acc_events ADD CONSTRAINT recharge_acc_events_kind_check
CHECK (kind IN (
    'agent_adjustment', 'agent_return', 'credit_reversal',
    'customer_refund', 'failed_reversal', 'commission_reversal',
    'recharge_correction', 'recharge_detail_edit'));

-- One correction per recharge.
CREATE UNIQUE INDEX IF NOT EXISTS idx_acc_events_one_correction
ON public.recharge_acc_events (shop_id, txn_key)
WHERE kind = 'recharge_correction';

ALTER TABLE public.recharge_transactions ADD COLUMN IF NOT EXISTS corrected_at TIMESTAMPTZ;
ALTER TABLE public.recharge_transactions ADD COLUMN IF NOT EXISTS corrected_by TEXT;
ALTER TABLE public.recharge_transactions ADD COLUMN IF NOT EXISTS correction_reason TEXT;

-- 2. Lock rule shared by both procedures.
CREATE OR REPLACE FUNCTION public.recharge_acc_require_unlocked_txn(
    p_shop_id TEXT, p_operator TEXT, p_created_at TIMESTAMPTZ
) RETURNS VOID AS $$
DECLARE
    v_prev public.recharge_period_snapshots;
BEGIN
    v_prev := public.recharge_acc_last_closing(p_shop_id, lower(p_operator));
    IF v_prev.snapshot_id IS NOT NULL AND p_created_at <= v_prev.created_at THEN
        RAISE EXCEPTION 'LOCKED_PERIOD: the closing after this recharge is verified';
    END IF;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- 3. Correction (wrong amount / operator): reverse the original.
CREATE OR REPLACE FUNCTION public.recharge_acc_correct_recharge(
    p_shop_id TEXT, p_txn_key TEXT, p_reason TEXT,
    p_idempotency_key TEXT, p_staff_id TEXT, p_device_id TEXT
) RETURNS JSONB AS $$
DECLARE
    v_txn RECORD;
    v_wallet RECORD;
    v_before BIGINT;
    v_credit BIGINT := 0;
    v_comm BIGINT := 0;
    v_event_id TEXT := 'CORR_' || p_txn_key;
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    PERFORM public.recharge_acc_require_key_reason(p_idempotency_key, p_reason, true);

    SELECT * INTO v_txn FROM public.recharge_transactions
    WHERE shop_id = p_shop_id AND txn_key = p_txn_key FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'UNKNOWN_RECHARGE: %', p_txn_key; END IF;

    PERFORM pg_advisory_xact_lock(hashtext('recharge_acc:' || p_shop_id || ':' || lower(v_txn.operator)));

    IF EXISTS (SELECT 1 FROM public.recharge_acc_events
               WHERE shop_id = p_shop_id AND kind = 'recharge_correction' AND txn_key = p_txn_key) THEN
        SELECT amount_paise INTO v_credit FROM public.recharge_acc_events
        WHERE shop_id = p_shop_id AND kind = 'recharge_correction' AND txn_key = p_txn_key;
        RETURN jsonb_build_object('success', true, 'replayed', true, 'reference_id', v_event_id,
            'walletCreditPaise', v_credit, 'status', 'reversed');
    END IF;
    IF v_txn.status <> 'completed' THEN
        RAISE EXCEPTION 'INVALID_STATUS: a % recharge cannot be corrected', v_txn.status;
    END IF;
    PERFORM public.recharge_acc_require_unlocked_txn(p_shop_id, v_txn.operator, v_txn.created_at);

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
        INSERT INTO public.recharge_wallet_logs (
            shop_id, log_id, wallet_id, txn_key, entry_type, amount_paise,
            balance_before_paise, balance_after_paise, description, staff_id, created_at, device_id,
            idempotency_key, reason, business_date
        ) VALUES (
            p_shop_id, v_event_id, v_txn.wallet_id, p_txn_key, 'reversal', v_credit,
            v_before, v_before + v_credit, 'Recharge correction (reversed): ' || p_reason, p_staff_id, v_now,
            COALESCE(p_device_id, 'DEV_UNSPECIFIED'), p_idempotency_key, p_reason,
            public.recharge_acc_ist_date(v_now)
        );
    END IF;

    -- Commission earned on the wrong entry is reversed (record only, no clawback).
    SELECT COALESCE(SUM(commission_paise), 0) INTO v_comm FROM public.recharge_commissions
    WHERE shop_id = p_shop_id AND txn_key = p_txn_key;
    IF v_comm > 0 AND NOT EXISTS (
        SELECT 1 FROM public.recharge_acc_events
        WHERE shop_id = p_shop_id AND kind = 'commission_reversal' AND txn_key = p_txn_key) THEN
        INSERT INTO public.recharge_acc_events (
            shop_id, event_id, kind, operator, txn_key, amount_paise, reason,
            business_date, idempotency_key, created_by, device_id, payload
        ) VALUES (
            p_shop_id, 'COMMREV_' || p_txn_key, 'commission_reversal', lower(v_txn.operator), p_txn_key,
            v_comm, 'Recharge corrected: ' || p_reason, public.recharge_acc_ist_date(v_now),
            p_idempotency_key || ':comm', p_staff_id, p_device_id,
            jsonb_build_object('wallet_clawback_paise', 0, 'from_correction', true)
        );
    ELSE
        v_comm := 0;
    END IF;

    UPDATE public.recharge_transactions
    SET status = 'reversed', corrected_at = v_now, corrected_by = p_staff_id, correction_reason = p_reason
    WHERE shop_id = p_shop_id AND txn_key = p_txn_key;

    INSERT INTO public.recharge_acc_events (
        shop_id, event_id, kind, operator, txn_key, amount_paise, payment_mode, reason,
        business_date, idempotency_key, created_by, device_id, payload
    ) VALUES (
        p_shop_id, v_event_id, 'recharge_correction', lower(v_txn.operator), p_txn_key, v_credit,
        v_txn.payment_mode, p_reason, public.recharge_acc_ist_date(v_now), p_idempotency_key,
        p_staff_id, p_device_id,
        jsonb_build_object('original_amount_paise', v_txn.amount_paise, 'customer_phone', v_txn.customer_phone,
            'funding_type', v_txn.funding_type, 'commission_reversed_paise', v_comm)
    );

    INSERT INTO public.recharge_audit_logs (shop_id, audit_id, event_type, actor_uid, device_id, entity_id, payload)
    VALUES (p_shop_id, gen_random_uuid()::text, 'ACC_RECHARGE_CORRECTION', p_staff_id, p_device_id, v_event_id,
        jsonb_build_object('txn', p_txn_key, 'wallet_credit', v_credit, 'commission_reversed', v_comm,
            'reason', p_reason));

    RETURN jsonb_build_object('success', true, 'replayed', false, 'reference_id', v_event_id,
        'walletCreditPaise', v_credit, 'commissionReversedPaise', v_comm, 'status', 'reversed');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4. Detail edit (mobile number, Cash <-> UPI). No money moves.
CREATE OR REPLACE FUNCTION public.recharge_acc_edit_recharge(
    p_shop_id TEXT, p_txn_key TEXT, p_customer_phone TEXT, p_payment_mode TEXT,
    p_reason TEXT, p_idempotency_key TEXT, p_staff_id TEXT, p_device_id TEXT
) RETURNS JSONB AS $$
DECLARE
    v_txn RECORD;
    v_phone TEXT := NULLIF(trim(COALESCE(p_customer_phone, '')), '');
    v_mode TEXT := NULLIF(trim(COALESCE(p_payment_mode, '')), '');
    v_event_id TEXT := 'EDIT_' || p_idempotency_key;
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    PERFORM public.recharge_acc_require_key_reason(p_idempotency_key, p_reason, true);

    IF EXISTS (SELECT 1 FROM public.recharge_acc_events
               WHERE shop_id = p_shop_id AND idempotency_key = p_idempotency_key) THEN
        RETURN jsonb_build_object('success', true, 'replayed', true, 'reference_id', v_event_id);
    END IF;
    IF v_phone IS NULL AND v_mode IS NULL THEN RAISE EXCEPTION 'NOTHING_TO_CHANGE'; END IF;
    IF v_phone IS NOT NULL AND v_phone !~ '^[0-9]{10}$' THEN
        RAISE EXCEPTION 'INVALID_PHONE: % (10 digits)', v_phone;
    END IF;
    IF v_mode IS NOT NULL AND v_mode NOT IN ('Cash', 'UPI') THEN
        RAISE EXCEPTION 'INVALID_PAYMENT_MODE: only Cash or UPI (use a correction for Credit / Due)';
    END IF;

    SELECT * INTO v_txn FROM public.recharge_transactions
    WHERE shop_id = p_shop_id AND txn_key = p_txn_key FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'UNKNOWN_RECHARGE: %', p_txn_key; END IF;
    IF v_txn.status <> 'completed' THEN
        RAISE EXCEPTION 'INVALID_STATUS: a % recharge cannot be edited', v_txn.status;
    END IF;
    IF v_mode IS NOT NULL AND COALESCE(v_txn.payment_mode, 'Cash') NOT IN ('Cash', 'UPI') THEN
        RAISE EXCEPTION 'INVALID_PAYMENT_MODE: a % recharge needs a correction', v_txn.payment_mode;
    END IF;
    PERFORM public.recharge_acc_require_unlocked_txn(p_shop_id, v_txn.operator, v_txn.created_at);

    UPDATE public.recharge_transactions
    SET customer_phone = COALESCE(v_phone, customer_phone),
        payment_mode = COALESCE(v_mode, payment_mode)
    WHERE shop_id = p_shop_id AND txn_key = p_txn_key;

    INSERT INTO public.recharge_acc_events (
        shop_id, event_id, kind, operator, txn_key, amount_paise, payment_mode, reason,
        business_date, idempotency_key, created_by, device_id, payload
    ) VALUES (
        p_shop_id, v_event_id, 'recharge_detail_edit', lower(v_txn.operator), p_txn_key, 0,
        COALESCE(v_mode, v_txn.payment_mode), p_reason, public.recharge_acc_ist_date(v_now),
        p_idempotency_key, p_staff_id, p_device_id,
        jsonb_build_object('old_phone', v_txn.customer_phone, 'new_phone', COALESCE(v_phone, v_txn.customer_phone),
            'old_payment_mode', v_txn.payment_mode, 'new_payment_mode', COALESCE(v_mode, v_txn.payment_mode))
    );

    INSERT INTO public.recharge_audit_logs (shop_id, audit_id, event_type, actor_uid, device_id, entity_id, payload)
    VALUES (p_shop_id, gen_random_uuid()::text, 'ACC_RECHARGE_DETAIL_EDIT', p_staff_id, p_device_id, v_event_id,
        jsonb_build_object('txn', p_txn_key, 'old_phone', v_txn.customer_phone, 'new_phone', v_phone,
            'old_mode', v_txn.payment_mode, 'new_mode', v_mode, 'reason', p_reason));

    RETURN jsonb_build_object('success', true, 'replayed', false, 'reference_id', v_event_id,
        'customerPhone', COALESCE(v_phone, v_txn.customer_phone),
        'paymentMode', COALESCE(v_mode, v_txn.payment_mode));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. Execution rights: only the Edge Function (service role).
REVOKE ALL ON FUNCTION public.recharge_acc_require_unlocked_txn(text, text, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.recharge_acc_correct_recharge(text, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.recharge_acc_edit_recharge(text, text, text, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.recharge_acc_require_unlocked_txn(text, text, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.recharge_acc_correct_recharge(text, text, text, text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.recharge_acc_edit_recharge(text, text, text, text, text, text, text, text) TO service_role;
