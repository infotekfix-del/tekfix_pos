-- ============================================================================
-- TEKFIX ERP - QUICK RECHARGE: DISTRIBUTOR OPENING DUES (fresh start)
-- Records an amount still owed to a distributor from before the fresh start,
-- whose wallet credit is ALREADY part of the operator's verified opening.
-- So: distributor payable + amount, wallet and recharge figures unchanged.
-- ADDITIVE ONLY. Integer paise. Owner-only via the edge function.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.recharge_acc_opening_dues(
    p_shop_id TEXT, p_distributor_id TEXT, p_operator TEXT, p_amount_paise BIGINT, p_reason TEXT,
    p_idempotency_key TEXT, p_staff_id TEXT, p_device_id TEXT
) RETURNS JSONB AS $$
DECLARE
    v_op TEXT := lower(p_operator);
    v_dist RECORD;
    v_before BIGINT;
    v_entry_id TEXT := 'ODUE_' || p_idempotency_key;
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    PERFORM public.recharge_acc_validate(v_op, p_amount_paise, p_idempotency_key, false, false);
    PERFORM public.recharge_acc_require_key_reason(p_idempotency_key, p_reason, true);

    SELECT * INTO v_dist FROM public.recharge_distributors
    WHERE shop_id = p_shop_id AND distributor_id = p_distributor_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'UNKNOWN_DISTRIBUTOR: %', p_distributor_id; END IF;

    IF EXISTS (SELECT 1 FROM public.recharge_distributor_ledger
               WHERE shop_id = p_shop_id AND idempotency_key = p_idempotency_key) THEN
        RETURN jsonb_build_object('success', true, 'replayed', true, 'reference_id', v_entry_id);
    END IF;

    v_before := public.recharge_acc_account_field(p_shop_id, p_distributor_id, v_op, 'balance_paise');

    -- Payable only: no wallet row is touched and no wallet log is written.
    INSERT INTO public.recharge_distributor_ledger (
        shop_id, entry_id, distributor_id, wallet_id, amount_paise, entry_type,
        balance_before_paise, balance_after_paise, payment_mode, reference_id, notes, created_at,
        operator, idempotency_key, signed_balance_before_paise, signed_balance_after_paise, created_by
    ) VALUES (
        p_shop_id, v_entry_id, p_distributor_id, public.recharge_acc_wallet_id(v_op), p_amount_paise,
        'credit_extended', GREATEST(v_before, 0), GREATEST(v_before + p_amount_paise, 0), 'credit_stock',
        v_entry_id, 'OPENING DUES: ' || p_reason, v_now,
        v_op, p_idempotency_key, v_before, v_before + p_amount_paise, p_staff_id
    );

    UPDATE public.recharge_distributors
    SET outstanding_balance_paise = outstanding_balance_paise + p_amount_paise
    WHERE shop_id = p_shop_id AND distributor_id = p_distributor_id;

    INSERT INTO public.recharge_audit_logs (shop_id, audit_id, event_type, actor_uid, device_id, entity_id, payload)
    VALUES (p_shop_id, gen_random_uuid()::text, 'ACC_DISTRIBUTOR_OPENING_DUES', p_staff_id, p_device_id, v_entry_id,
        jsonb_build_object('distributor', p_distributor_id, 'operator', v_op, 'amount', p_amount_paise,
            'reason', p_reason, 'before', v_before, 'after', v_before + p_amount_paise));

    RETURN jsonb_build_object('success', true, 'replayed', false, 'reference_id', v_entry_id,
        'balanceBeforePaise', v_before, 'balanceAfterPaise', v_before + p_amount_paise);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE ALL ON FUNCTION public.recharge_acc_opening_dues(text,text,text,bigint,text,text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.recharge_acc_opening_dues(text,text,text,bigint,text,text,text,text) TO service_role;
