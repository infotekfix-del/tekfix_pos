-- ============================================================================
-- QUICK RECHARGE: EXCESS ACCOUNT (owner decision 2026-11-21)
-- Shop rule: the shop never tops up with its own money. Extra morning balance
-- is distributor credit (payable by next morning); anything left over is
-- EXCESS. A positive closing variance is also EXCESS. Excess is a separate
-- account: never profit, never own money. A shortage is only shown.
--   * recharge_acc_post_classified: REPLACED (same signature), adds category
--     'excess' (positive, capped by the unexplained amount like a top-up,
--     not an adjustment). Body otherwise identical to 20261120000001.
--   * recharge_acc_excess(shop): read of the Excess account.
-- ADDITIVE: no table change, no row update. NOT TESTED (no Supabase CLI here).
-- ============================================================================

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
    IF p_category NOT IN ('topUpOwn', 'topUpDistributorCredit', 'excess', 'refund', 'bonus',
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
        ELSE 'adjustment' END; -- excess: +adjustment, category 'excess'

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

-- Excess account: morning 'excess' classifications + positive closing variances.
CREATE OR REPLACE FUNCTION public.recharge_acc_excess(p_shop_id TEXT)
RETURNS JSONB AS $$
    SELECT jsonb_build_object('success', true, 'entries', COALESCE(jsonb_agg(x ORDER BY x->>'at'), '[]'::jsonb))
    FROM (
        SELECT jsonb_build_object(
            'operator', lower(w.operator), 'amount_paise', l.amount_paise, 'at', l.created_at,
            'source', 'morning', 'reference_id', l.log_id) AS x
        FROM public.recharge_wallet_logs l
        JOIN public.recharge_wallets w ON w.shop_id = l.shop_id AND w.wallet_id = l.wallet_id
        WHERE l.shop_id = p_shop_id AND l.category = 'excess'
        UNION ALL
        SELECT jsonb_build_object(
            'operator', s.operator, 'amount_paise', s.variance_paise, 'at', s.created_at,
            'source', 'closing', 'reference_id', s.snapshot_id)
        FROM public.recharge_period_snapshots s
        WHERE s.shop_id = p_shop_id AND s.kind = 'closing' AND s.variance_paise > 0
    ) q;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

DO $$
DECLARE
    fn TEXT;
BEGIN
    FOREACH fn IN ARRAY ARRAY[
        'recharge_acc_post_classified(text,text,text,bigint,text,timestamptz,text,text,text,text,text)',
        'recharge_acc_excess(text)'
    ] LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon, authenticated;', fn);
        EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO service_role;', fn);
    END LOOP;
END $$;
