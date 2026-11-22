-- ============================================================================
-- QUICK RECHARGE: DISTRIBUTOR TOP-UP COMMISSION (owner decision 2026-11-21)
-- A distributor refill of Rs 1,039 is Rs 1,000 payable + Rs 39 commission
-- (3.9%). The shop pays the agent only Rs 1,000; the Rs 39 is profit.
--   * The payable part is posted by the existing paths (distributor load /
--     morning classification 'topUpDistributorCredit').
--   * recharge_acc_topup_commission: posts the commission part as a wallet
--     credit (entry_type 'credit', log_id 'TUC_<key>'). category stays NULL
--     so a mid-day posting never touches the morning classification.
--   * recharge_acc_topup_commission_summary: commission read (mid-day
--     'TUC_' credits + morning 'commissionCredit' classifications).
-- ADDITIVE: new functions only. NOT TESTED (no Supabase CLI here).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.recharge_acc_topup_commission(
    p_shop_id TEXT, p_operator TEXT, p_distributor_id TEXT, p_commission_paise BIGINT,
    p_reason TEXT, p_idempotency_key TEXT, p_staff_id TEXT, p_staff_name TEXT, p_device_id TEXT
) RETURNS JSONB AS $$
DECLARE
    v_op TEXT := lower(p_operator);
    v_wallet_id TEXT := public.recharge_acc_wallet_id(p_operator);
    v_wallet RECORD;
    v_log_id TEXT := 'TUC_' || p_idempotency_key;
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    PERFORM public.recharge_acc_validate(v_op, p_commission_paise, p_idempotency_key, false, false);
    IF COALESCE(trim(p_reason), '') = '' THEN RAISE EXCEPTION 'REASON_REQUIRED'; END IF;
    IF p_commission_paise > 10000000 THEN
        RAISE EXCEPTION 'AMOUNT_LIMIT: commission must be within Rs 1,00,000';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('recharge_acc:' || p_shop_id || ':' || v_op));

    IF EXISTS (SELECT 1 FROM public.recharge_wallet_logs WHERE shop_id = p_shop_id AND idempotency_key = p_idempotency_key) THEN
        RETURN jsonb_build_object('success', true, 'replayed', true, 'reference_id', v_log_id);
    END IF;

    IF COALESCE(p_distributor_id, '') <> '' AND NOT EXISTS (
        SELECT 1 FROM public.recharge_distributors
        WHERE shop_id = p_shop_id AND distributor_id = p_distributor_id) THEN
        RAISE EXCEPTION 'UNKNOWN_DISTRIBUTOR: %', p_distributor_id;
    END IF;

    SELECT * INTO v_wallet FROM public.recharge_wallets
    WHERE shop_id = p_shop_id AND wallet_id = v_wallet_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Wallet % not found', v_wallet_id; END IF;

    UPDATE public.recharge_wallets
    SET own_prepaid_balance_paise = own_prepaid_balance_paise + p_commission_paise, last_updated_at = v_now
    WHERE shop_id = p_shop_id AND wallet_id = v_wallet_id;

    INSERT INTO public.recharge_wallet_logs (
        shop_id, log_id, wallet_id, entry_type, amount_paise, balance_before_paise, balance_after_paise,
        description, staff_id, staff_name, created_at, device_id,
        idempotency_key, reason, distributor_id, business_date
    ) VALUES (
        p_shop_id, v_log_id, v_wallet_id, 'credit', p_commission_paise,
        v_wallet.total_balance_paise, v_wallet.total_balance_paise + p_commission_paise,
        'Distributor top-up commission', p_staff_id, p_staff_name, v_now,
        COALESCE(p_device_id, 'DEV_UNSPECIFIED'), p_idempotency_key, p_reason,
        NULLIF(p_distributor_id, ''), public.recharge_acc_ist_date(v_now)
    );

    INSERT INTO public.recharge_audit_logs (shop_id, audit_id, event_type, actor_uid, device_id, entity_id, payload)
    VALUES (p_shop_id, gen_random_uuid()::text, 'ACC_TOPUP_COMMISSION', p_staff_id, p_device_id, v_log_id,
        jsonb_build_object('operator', v_op, 'distributor', p_distributor_id,
            'commission', p_commission_paise, 'reason', p_reason));

    RETURN jsonb_build_object('success', true, 'replayed', false, 'reference_id', v_log_id,
        'commissionPaise', p_commission_paise);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.recharge_acc_topup_commission_summary(p_shop_id TEXT)
RETURNS JSONB AS $$
    SELECT jsonb_build_object('success', true, 'entries', COALESCE(jsonb_agg(jsonb_build_object(
        'operator', lower(w.operator), 'amount_paise', l.amount_paise, 'at', l.created_at,
        'reference_id', l.log_id) ORDER BY l.created_at), '[]'::jsonb))
    FROM public.recharge_wallet_logs l
    JOIN public.recharge_wallets w ON w.shop_id = l.shop_id AND w.wallet_id = l.wallet_id
    WHERE l.shop_id = p_shop_id
      AND (l.log_id LIKE 'TUC\_%' OR l.category = 'commissionCredit');
$$ LANGUAGE sql STABLE SECURITY DEFINER;

DO $$
DECLARE
    fn TEXT;
BEGIN
    FOREACH fn IN ARRAY ARRAY[
        'recharge_acc_topup_commission(text,text,text,bigint,text,text,text,text,text)',
        'recharge_acc_topup_commission_summary(text)'
    ] LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon, authenticated;', fn);
        EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO service_role;', fn);
    END LOOP;
END $$;
