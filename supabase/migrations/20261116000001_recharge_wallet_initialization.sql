-- ============================================================================
-- TEKFIX ERP - PHASE 16.4.8: IDEMPOTENT RECHARGE WALLET INITIALIZATION
-- SAFE PROVISIONING OF OPERATOR MASTER WALLETS (AIRTEL, JIO, VI, BSNL)
-- ZERO FLOATING POINT, ZERO OVERWRITES, STRICT INTEGER PAISE FIDELITY
-- ============================================================================

-- 1. Idempotent Stored Procedure: Initialize Core Operator Wallets for a Shop
CREATE OR REPLACE FUNCTION public.recharge_initialize_shop_wallets(p_shop_id TEXT)
RETURNS JSONB AS $$
DECLARE
    v_inserted INT := 0;
BEGIN
    IF p_shop_id IS NULL OR TRIM(p_shop_id) = '' THEN
        RAISE EXCEPTION 'Shop ID cannot be null or empty';
    END IF;

    -- Idempotently insert missing wallets with initial zero balances
    -- ON CONFLICT (shop_id, wallet_id) DO NOTHING strictly preserves all existing balances & history
    INSERT INTO public.recharge_wallets (
        shop_id,
        wallet_id,
        operator,
        sim_number,
        own_prepaid_balance_paise,
        distributor_credit_balance_paise,
        last_updated_at
    ) VALUES
        (p_shop_id, 'WALLET_AIRTEL', 'Airtel', '', 0, 0, now()),
        (p_shop_id, 'WALLET_JIO',    'Jio',    '', 0, 0, now()),
        (p_shop_id, 'WALLET_VI',     'Vi',     '', 0, 0, now()),
        (p_shop_id, 'WALLET_BSNL',   'BSNL',   '', 0, 0, now())
    ON CONFLICT (shop_id, wallet_id) DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'shop_id', p_shop_id,
        'wallets_created', v_inserted,
        'message', 'Shop operator wallets initialized successfully'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 2. Enhanced Stored Procedure: Atomic Wallet Debit with Self-Healing Wallet Provisioning
CREATE OR REPLACE FUNCTION public.recharge_process_debit(
    p_shop_id TEXT,
    p_wallet_id TEXT,
    p_txn_key TEXT,
    p_idempotency_key TEXT,
    p_customer_phone TEXT,
    p_operator TEXT,
    p_service_type TEXT,
    p_amount_paise BIGINT,
    p_funding_type TEXT,
    p_commission_earned_paise BIGINT,
    p_business_date DATE,
    p_device_id TEXT,
    p_owner_uid TEXT,
    p_notes TEXT DEFAULT NULL,
    p_payment_mode TEXT DEFAULT 'Cash',
    p_retail_amount_paise BIGINT DEFAULT NULL,
    p_cost_price_paise BIGINT DEFAULT NULL,
    p_party_key TEXT DEFAULT NULL,
    p_party_name TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_wallet RECORD;
    v_new_own BIGINT;
    v_new_dist BIGINT;
    v_balance_before BIGINT;
    v_balance_after BIGINT;
    v_existing RECORD;
    v_retail_paise BIGINT;
    v_cost_paise BIGINT;
BEGIN
    v_retail_paise := COALESCE(p_retail_amount_paise, p_amount_paise);
    v_cost_paise := COALESCE(p_cost_price_paise, p_amount_paise - COALESCE(p_commission_earned_paise, 0));

    -- Idempotency Check by (shop_id, idempotency_key)
    SELECT * INTO v_existing FROM public.recharge_transactions 
    WHERE shop_id = p_shop_id AND idempotency_key = p_idempotency_key;
    
    IF FOUND THEN
        IF v_existing.wallet_debited = true THEN
            -- Retrieve current wallet balance to return
            SELECT total_balance_paise INTO v_balance_after FROM public.recharge_wallets
            WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id;
            
            RETURN jsonb_build_object(
                'success', true,
                'idempotent_replay', true,
                'txn_key', v_existing.txn_key,
                'amount_paise', v_existing.amount_paise,
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
        -- Auto-initialize shop wallets idempotently if not yet provisioned
        PERFORM public.recharge_initialize_shop_wallets(p_shop_id);

        SELECT * INTO v_wallet FROM public.recharge_wallets 
        WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id 
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Wallet % for shop % not found', p_wallet_id, p_shop_id;
        END IF;
    END IF;

    v_new_own := v_wallet.own_prepaid_balance_paise;
    v_new_dist := v_wallet.distributor_credit_balance_paise;
    v_balance_before := v_wallet.total_balance_paise;

    -- Negative Balance Prevention & Invariant Verification
    IF p_funding_type = 'distributorCredit' THEN
        IF v_new_dist < p_amount_paise THEN
            RAISE EXCEPTION 'Insufficient distributor credit balance: Available % paise, requested % paise', v_new_dist, p_amount_paise;
        END IF;
        v_new_dist := v_new_dist - p_amount_paise;
    ELSE
        IF v_new_own < p_amount_paise THEN
            RAISE EXCEPTION 'Insufficient own prepaid balance: Available % paise, requested % paise', v_new_own, p_amount_paise;
        END IF;
        v_new_own := v_new_own - p_amount_paise;
    END IF;

    v_balance_after := v_new_own + v_new_dist;

    -- Atomic Wallet Balance Update
    UPDATE public.recharge_wallets
    SET own_prepaid_balance_paise = v_new_own,
        distributor_credit_balance_paise = v_new_dist,
        last_updated_at = now()
    WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id;

    -- Insert Transaction Record with Payment Mode Breakdown
    INSERT INTO public.recharge_transactions (
        shop_id, txn_key, wallet_id, customer_phone, operator, service_type,
        amount_paise, funding_type, commission_earned_paise, wallet_debited,
        status, device_id, owner_uid, business_date, idempotency_key, notes,
        payment_mode, retail_amount_paise, cost_price_paise, party_key, party_name, created_at
    ) VALUES (
        p_shop_id, p_txn_key, p_wallet_id, p_customer_phone, p_operator, COALESCE(p_service_type, 'mobile_recharge'),
        p_amount_paise, p_funding_type, p_commission_earned_paise, true,
        'completed', p_device_id, p_owner_uid, p_business_date, p_idempotency_key, p_notes,
        COALESCE(p_payment_mode, 'Cash'), v_retail_paise, v_cost_paise, p_party_key, p_party_name, now()
    );

    -- Insert Double-Entry Ledger Entry
    INSERT INTO public.recharge_wallet_logs (
        shop_id, log_id, wallet_id, txn_key, entry_type,
        amount_paise, balance_before_paise, balance_after_paise, description, staff_id, created_at
    ) VALUES (
        p_shop_id, gen_random_uuid()::text, p_wallet_id, p_txn_key, 'debit',
        p_amount_paise, v_balance_before, v_balance_after, 
        'Recharge debit: ' || p_operator || ' (' || p_customer_phone || ') [' || COALESCE(p_payment_mode, 'Cash') || ']', 
        p_owner_uid, now()
    );

    -- Auto-record commission if applicable
    IF p_commission_earned_paise > 0 THEN
        INSERT INTO public.recharge_commissions (
            shop_id, commission_id, txn_key, operator, recharge_amount_paise,
            commission_paise, business_date, is_settled, created_at
        ) VALUES (
            p_shop_id, gen_random_uuid()::text, p_txn_key, p_operator,
            p_amount_paise, p_commission_earned_paise, p_business_date, false, now()
        );
    END IF;

    -- Return JSON result
    RETURN jsonb_build_object(
        'success', true,
        'idempotent_replay', false,
        'txn_key', p_txn_key,
        'balance_before_paise', v_balance_before,
        'balance_after_paise', v_balance_after,
        'total_balance_paise', v_balance_after,
        'own_prepaid_balance_paise', v_new_own,
        'distributor_credit_balance_paise', v_new_dist,
        'payment_mode', COALESCE(p_payment_mode, 'Cash')
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 3. Enhanced Stored Procedure: Atomic Wallet Top-Up with Self-Healing Wallet Provisioning
CREATE OR REPLACE FUNCTION public.recharge_process_topup(
    p_shop_id TEXT,
    p_wallet_id TEXT,
    p_amount_paise BIGINT,
    p_source TEXT,
    p_staff_id TEXT,
    p_staff_name TEXT,
    p_reference_id TEXT DEFAULT NULL,
    p_description TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_wallet RECORD;
    v_new_own BIGINT;
    v_balance_before BIGINT;
    v_balance_after BIGINT;
    v_ref TEXT := COALESCE(p_reference_id, gen_random_uuid()::text);
BEGIN
    IF p_amount_paise <= 0 THEN
        RAISE EXCEPTION 'Top-up amount must be strictly positive: %', p_amount_paise;
    END IF;

    -- Lock wallet row
    SELECT * INTO v_wallet FROM public.recharge_wallets
    WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id
    FOR UPDATE;

    IF NOT FOUND THEN
        -- Auto-initialize shop wallets idempotently if not yet provisioned
        PERFORM public.recharge_initialize_shop_wallets(p_shop_id);

        SELECT * INTO v_wallet FROM public.recharge_wallets
        WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Wallet % for shop % not found', p_wallet_id, p_shop_id;
        END IF;
    END IF;

    v_balance_before := v_wallet.total_balance_paise;
    v_new_own := v_wallet.own_prepaid_balance_paise + p_amount_paise;
    v_balance_after := v_new_own + v_wallet.distributor_credit_balance_paise;

    -- Update balance
    UPDATE public.recharge_wallets
    SET own_prepaid_balance_paise = v_new_own,
        last_updated_at = now()
    WHERE shop_id = p_shop_id AND wallet_id = p_wallet_id;

    -- Ledger Log
    INSERT INTO public.recharge_wallet_logs (
        shop_id, log_id, wallet_id, txn_key, entry_type,
        amount_paise, balance_before_paise, balance_after_paise, description, staff_id, staff_name, created_at
    ) VALUES (
        p_shop_id, v_ref, p_wallet_id, NULL, 'topup',
        p_amount_paise, v_balance_before, v_balance_after, COALESCE(p_description, 'Prepaid wallet top-up'), p_staff_id, p_staff_name, now()
    );

    -- Float deposit record
    INSERT INTO public.recharge_float_deposits (
        shop_id, deposit_id, wallet_id, amount_paise, source, deposited_by, reference_no, notes, created_at
    ) VALUES (
        p_shop_id, v_ref, p_wallet_id, p_amount_paise, COALESCE(p_source, 'bank'), p_staff_id, p_reference_id, p_description, now()
    );

    RETURN jsonb_build_object(
        'success', true,
        'wallet_id', p_wallet_id,
        'balance_before_paise', v_balance_before,
        'balance_after_paise', v_balance_after,
        'own_prepaid_balance_paise', v_new_own,
        'distributor_credit_balance_paise', v_wallet.distributor_credit_balance_paise,
        'reference_id', v_ref
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 4. Immediate Idempotent Provisioning for Production and Staging Shops
-- Initializes Airtel, Jio, Vi, BSNL with exactly 0 paise.
-- ON CONFLICT DO NOTHING guarantees zero overwrites if rows already exist.
SELECT public.recharge_initialize_shop_wallets('tekfix');
SELECT public.recharge_initialize_shop_wallets('shop_staging_001');
