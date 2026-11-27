-- ============================================================================
-- TEKFIX ERP - PHASE 16.2: RECHARGE PAYMENT MODES & FINANCIAL CONSISTENCY
-- EXTENDS FINANCIAL PROCEDURES TO BIND PAYMENT MODE (CASH / UPI / DUE)
-- RETAIL PRICE, COST PRICE, AND CUSTOMER RECEIVABLES AT THE SERVER LEVEL
-- ============================================================================

-- 1. Add Payment Mode & Price Breakdown Columns to Transactions
ALTER TABLE public.recharge_transactions 
ADD COLUMN IF NOT EXISTS payment_mode TEXT DEFAULT 'Cash' 
CHECK (payment_mode IN ('Cash', 'UPI', 'Credit / Due'));

ALTER TABLE public.recharge_transactions 
ADD COLUMN IF NOT EXISTS retail_amount_paise BIGINT 
CHECK (retail_amount_paise IS NULL OR retail_amount_paise >= 0);

ALTER TABLE public.recharge_transactions 
ADD COLUMN IF NOT EXISTS cost_price_paise BIGINT 
CHECK (cost_price_paise IS NULL OR cost_price_paise >= 0);

ALTER TABLE public.recharge_transactions 
ADD COLUMN IF NOT EXISTS party_key TEXT;

ALTER TABLE public.recharge_transactions 
ADD COLUMN IF NOT EXISTS party_name TEXT;

-- Index for payment mode analytics
CREATE INDEX IF NOT EXISTS idx_recharge_transactions_payment_mode 
ON public.recharge_transactions (shop_id, payment_mode);

-- 2. Enhanced Stored Procedure: Atomic Wallet Debit with Payment Consistency
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
        RAISE EXCEPTION 'Wallet % for shop % not found', p_wallet_id, p_shop_id;
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

