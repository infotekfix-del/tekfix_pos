-- ============================================================================
-- TEKFIX ERP - QUICK RECHARGE: WALLET OPENING ALIGNMENT (fresh start)
-- Brings the system wallet (recharge_wallets) to the owner's verified balance
-- for the current period, so recharge debits are checked against the real
-- balance. The alignment is audited but is NOT a period movement: it never
-- changes the expected closing, recharge volume or distributor settlement.
-- ADDITIVE: one new procedure; recharge_acc_movements gains one filter.
-- ============================================================================

-- Alignment rows are marked with reference_no = 'OPENING_ALIGNMENT' and are
-- left out of the period movements (they only correct the system wallet).
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
      AND COALESCE(l.reference_no, '') <> 'OPENING_ALIGNMENT'
      AND (p_from IS NULL OR l.created_at > p_from)
      AND (p_to IS NULL OR l.created_at <= p_to)
    ORDER BY l.created_at;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION public.recharge_acc_align_wallet(
    p_shop_id TEXT, p_operator TEXT, p_own_paise BIGINT, p_credit_paise BIGINT, p_reason TEXT,
    p_idempotency_key TEXT, p_staff_id TEXT, p_device_id TEXT
) RETURNS JSONB AS $$
DECLARE
    v_op TEXT := lower(p_operator);
    v_wallet_id TEXT := public.recharge_acc_wallet_id(p_operator);
    v_prev public.recharge_period_snapshots;
    v_pid TEXT;
    v_net BIGINT;
    v_expected BIGINT;
    v_wallet RECORD;
    v_before BIGINT;
    v_after BIGINT;
    v_diff BIGINT;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_log_id TEXT := 'ALIGN_' || p_idempotency_key;
BEGIN
    PERFORM public.recharge_acc_validate(v_op, p_own_paise + p_credit_paise, p_idempotency_key, false, true);
    PERFORM public.recharge_acc_require_key_reason(p_idempotency_key, p_reason, true);
    IF p_own_paise IS NULL OR p_credit_paise IS NULL OR p_own_paise < 0 OR p_credit_paise < 0 THEN
        RAISE EXCEPTION 'INVALID_AMOUNT: own and credit must be zero or more';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('recharge_acc:' || p_shop_id || ':' || v_op));

    IF EXISTS (SELECT 1 FROM public.recharge_wallet_logs WHERE shop_id = p_shop_id AND idempotency_key = p_idempotency_key)
       OR EXISTS (SELECT 1 FROM public.recharge_audit_logs WHERE shop_id = p_shop_id AND entity_id = v_log_id) THEN
        RETURN jsonb_build_object('success', true, 'replayed', true, 'reference_id', v_log_id);
    END IF;

    -- The aligned total must equal the verified opening + this period's movements.
    v_prev := public.recharge_acc_last_closing(p_shop_id, v_op);
    IF v_prev.snapshot_id IS NULL THEN
        RAISE EXCEPTION 'PREVIOUS_CLOSING_MISSING: enter a verified reference balance first';
    END IF;
    v_pid := public.recharge_acc_period_id(v_op, v_prev.created_at);
    SELECT COALESCE(SUM(public.recharge_acc_signed(m.kind, m.amount_paise, m.pending)), 0) INTO v_net
    FROM public.recharge_acc_movements(p_shop_id, v_op, v_prev.created_at, v_now) m;
    v_expected := v_prev.actual_paise + v_net;
    IF p_own_paise + p_credit_paise <> v_expected THEN
        RAISE EXCEPTION 'ALIGNMENT_MISMATCH: own + credit must equal the current verified balance % paise', v_expected;
    END IF;

    SELECT * INTO v_wallet FROM public.recharge_wallets
    WHERE shop_id = p_shop_id AND wallet_id = v_wallet_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Wallet % not found', v_wallet_id; END IF;

    v_before := v_wallet.total_balance_paise;
    v_after := p_own_paise + p_credit_paise;
    v_diff := v_after - v_before;

    UPDATE public.recharge_wallets
    SET own_prepaid_balance_paise = p_own_paise,
        distributor_credit_balance_paise = p_credit_paise,
        last_updated_at = v_now
    WHERE shop_id = p_shop_id AND wallet_id = v_wallet_id;

    IF v_diff <> 0 THEN
        INSERT INTO public.recharge_wallet_logs (
            shop_id, log_id, wallet_id, entry_type, amount_paise, balance_before_paise, balance_after_paise,
            description, staff_id, staff_name, created_at, device_id,
            adjustment_sign, period_id, idempotency_key, reason, reference_no, business_date
        ) VALUES (
            p_shop_id, v_log_id, v_wallet_id, 'adjustment', abs(v_diff), v_before, v_after,
            'Opening alignment to verified balance', p_staff_id, '', v_now, COALESCE(p_device_id, 'DEV_UNSPECIFIED'),
            CASE WHEN v_diff < 0 THEN -1 ELSE 1 END, v_pid, p_idempotency_key, p_reason, 'OPENING_ALIGNMENT',
            public.recharge_acc_ist_date(v_now)
        );
    END IF;

    INSERT INTO public.recharge_audit_logs (shop_id, audit_id, event_type, actor_uid, device_id, entity_id, payload)
    VALUES (p_shop_id, gen_random_uuid()::text, 'ACC_WALLET_OPENING_ALIGNMENT', p_staff_id, p_device_id, v_log_id,
        jsonb_build_object('operator', v_op, 'reason', p_reason,
            'own_before', v_wallet.own_prepaid_balance_paise, 'credit_before', v_wallet.distributor_credit_balance_paise,
            'own_after', p_own_paise, 'credit_after', p_credit_paise, 'period', v_pid));

    RETURN jsonb_build_object('success', true, 'replayed', false, 'reference_id', v_log_id,
        'balanceBeforePaise', v_before, 'balanceAfterPaise', v_after);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE ALL ON FUNCTION public.recharge_acc_align_wallet(text,text,bigint,bigint,text,text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.recharge_acc_align_wallet(text,text,bigint,bigint,text,text,text,text) TO service_role;
