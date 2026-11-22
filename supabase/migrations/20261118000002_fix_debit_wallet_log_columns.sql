-- ============================================================================
-- FIX: recharge_process_debit wallet-log insert used columns that do not exist
-- (funding_type, reference_id) and entry_type 'RECHARGE_DEBIT', which violates
-- recharge_wallet_logs_entry_type_check. Now: txn_key + 'debit' + device_id.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.recharge_process_debit(
    p_shop_id text,
    p_wallet_id text,
    p_txn_key text,
    p_idempotency_key text,
    p_customer_phone text,
    p_operator text,
    p_service_type text,
    p_amount_paise bigint,
    p_funding_type text,
    p_commission_earned_paise bigint,
    p_business_date date,
    p_device_id text,
    p_owner_uid text,
    p_notes text DEFAULT NULL::text,
    p_payment_mode text DEFAULT 'Cash'::text,
    p_retail_amount_paise bigint DEFAULT NULL::bigint,
    p_cost_price_paise bigint DEFAULT NULL::bigint,
    p_party_key text DEFAULT NULL::text,
    p_party_name text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_wallet RECORD;
    v_new_own BIGINT;
    v_new_dist BIGINT;
    v_balance_before BIGINT;
    v_balance_after BIGINT;
    v_existing RECORD;
    v_retail_paise BIGINT;
    v_cost_paise BIGINT;
    v_norm_op TEXT;
    v_comm_enabled BOOLEAN := true;
    v_effective_comm_paise BIGINT;
BEGIN
    v_retail_paise := COALESCE(p_retail_amount_paise, p_amount_paise);
    v_effective_comm_paise := COALESCE(p_commission_earned_paise, 0);

    -- Server-Authoritative Commission Control Lookup
    v_norm_op := UPPER(TRIM(COALESCE(p_operator, 'OTHER')));
    SELECT is_enabled INTO v_comm_enabled 
    FROM public.recharge_commission_controls 
    WHERE shop_id = p_shop_id AND operator = v_norm_op;

    IF FOUND AND v_comm_enabled = false THEN
        -- When Commission is OFF: Force 0 commission and full retail cost
        v_effective_comm_paise := 0;
        v_cost_paise := v_retail_paise;
    ELSE
        -- When Commission is ON: calculate cost price
        v_cost_paise := COALESCE(p_cost_price_paise, v_retail_paise - v_effective_comm_paise);
    END IF;

    -- Fast-path Idempotency Check by (shop_id, idempotency_key)
    SELECT * INTO v_existing FROM public.recharge_transactions 
    WHERE shop_id = p_shop_id AND idempotency_key = p_idempotency_key;
    
    IF FOUND THEN
        IF v_existing.wallet_debited = true THEN
            SELECT total_balance_paise INTO v_balance_after FROM public.recharge_wallets
            WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id;
            
            RETURN jsonb_build_object(
                'success', true,
                'idempotent_replay', true,
                'txn_key', v_existing.txn_key,
                'amount_paise', v_existing.amount_paise,
                'commission_earned_paise', v_existing.commission_earned_paise,
                'total_balance_paise', v_balance_after,
                'payment_mode', v_existing.payment_mode
            );
        ELSE
            RAISE EXCEPTION 'Transaction already exists in incomplete state: %', v_existing.txn_key;
        END IF;
    END IF;

    -- Concurrency Row Lock: Serialize concurrent debit operations on this wallet
    SELECT * INTO v_wallet FROM public.recharge_wallets 
    WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id 
    FOR UPDATE;

    IF NOT FOUND THEN
        PERFORM public.recharge_initialize_shop_wallets(p_shop_id);

        SELECT * INTO v_wallet FROM public.recharge_wallets 
        WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id 
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Wallet % for shop % not found', p_wallet_id, p_shop_id;
        END IF;
    END IF;

    -- Concurrency-Safe Idempotency Re-Check under FOR UPDATE lock
    SELECT * INTO v_existing FROM public.recharge_transactions 
    WHERE shop_id = p_shop_id AND idempotency_key = p_idempotency_key;
    
    IF FOUND THEN
        IF v_existing.wallet_debited = true THEN
            SELECT total_balance_paise INTO v_balance_after FROM public.recharge_wallets
            WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id;
            
            RETURN jsonb_build_object(
                'success', true,
                'idempotent_replay', true,
                'txn_key', v_existing.txn_key,
                'amount_paise', v_existing.amount_paise,
                'commission_earned_paise', v_existing.commission_earned_paise,
                'total_balance_paise', v_balance_after,
                'payment_mode', v_existing.payment_mode
            );
        ELSE
            RAISE EXCEPTION 'Transaction already exists in incomplete state: %', v_existing.txn_key;
        END IF;
    END IF;

    -- Evaluate Sufficient Funds based on debit amount (v_cost_paise)
    v_balance_before := v_wallet.total_balance_paise;
    IF p_funding_type = 'distributorCredit' THEN
        IF v_wallet.distributor_credit_balance_paise < v_cost_paise THEN
            RAISE EXCEPTION 'INSUFFICIENT_DISTRIBUTOR_CREDIT: Required % paise, available % paise', 
                v_cost_paise, v_wallet.distributor_credit_balance_paise;
        END IF;
        v_new_dist := v_wallet.distributor_credit_balance_paise - v_cost_paise;
        v_new_own := v_wallet.own_prepaid_balance_paise;
    ELSE
        IF v_wallet.own_prepaid_balance_paise < v_cost_paise THEN
            RAISE EXCEPTION 'INSUFFICIENT_OWN_PREPAID: Required % paise, available % paise', 
                v_cost_paise, v_wallet.own_prepaid_balance_paise;
        END IF;
        v_new_own := v_wallet.own_prepaid_balance_paise - v_cost_paise;
        v_new_dist := v_wallet.distributor_credit_balance_paise;
    END IF;

    v_balance_after := v_new_own + v_new_dist;

    -- Update Wallet Balance
    UPDATE public.recharge_wallets SET
        own_prepaid_balance_paise = v_new_own,
        distributor_credit_balance_paise = v_new_dist,
        last_updated_at = now()
    WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id;

    -- Record Transaction
    INSERT INTO public.recharge_transactions (
        shop_id, txn_key, wallet_id, customer_phone, operator, service_type,
        amount_paise, funding_type, commission_earned_paise, wallet_debited,
        status, device_id, owner_uid, business_date, idempotency_key, notes,
        payment_mode, retail_amount_paise, cost_price_paise, party_key, party_name, created_at
    ) VALUES (
        p_shop_id, p_txn_key, p_wallet_id, p_customer_phone, p_operator, COALESCE(p_service_type, 'mobile_recharge'),
        v_cost_paise, p_funding_type, v_effective_comm_paise, true,
        'completed', p_device_id, p_owner_uid, p_business_date, p_idempotency_key, p_notes,
        COALESCE(p_payment_mode, 'Cash'), v_retail_paise, v_cost_paise, p_party_key, p_party_name, now()
    );

    -- Insert Double-Entry Ledger Entry
    INSERT INTO public.recharge_wallet_logs (
        shop_id, log_id, wallet_id, txn_key, entry_type, amount_paise,
        balance_before_paise, balance_after_paise, description,
        staff_id, device_id, created_at
    ) VALUES (
        p_shop_id, gen_random_uuid()::text, p_wallet_id, p_txn_key, 'debit', v_cost_paise,
        v_balance_before, v_balance_after,
        format('Recharge %s: %s [%s] (Retail: %s, Comm: %s)', p_operator, p_customer_phone, p_funding_type, v_retail_paise, v_effective_comm_paise),
        p_owner_uid, COALESCE(p_device_id, 'DEV_UNSPECIFIED'), now()
    );

    -- Auto-record commission ONLY if commission was enabled and > 0
    IF v_effective_comm_paise > 0 THEN
        INSERT INTO public.recharge_commissions (
            shop_id, commission_id, txn_key, operator, recharge_amount_paise,
            commission_paise, business_date, is_settled, created_at
        ) VALUES (
            p_shop_id, gen_random_uuid()::text, p_txn_key, p_operator,
            v_retail_paise, v_effective_comm_paise, p_business_date, false, now()
        );
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'txn_key', p_txn_key,
        'amount_paise', v_cost_paise,
        'retail_amount_paise', v_retail_paise,
        'commission_earned_paise', v_effective_comm_paise,
        'balance_before_paise', v_balance_before,
        'balance_after_paise', v_balance_after,
        'total_balance_paise', v_balance_after,
        'payment_mode', COALESCE(p_payment_mode, 'Cash')
    );
END;
$function$;
